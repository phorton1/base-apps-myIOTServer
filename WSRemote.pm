#!/usr/bin/perl
#-----------------------------------------------------
# apps::myIOTServer::WSRemote.pm
#-----------------------------------------------------
# WSRemote is an object that handles persistent
# WebSocket connections to remote javascript clients
# over HTTPS/WSS. Control is diverted here from the
# main HTTPS Server on requests to the url /ws.
#
# It works in conjunction with the Devices and
# the WSLocal to channel requests between external
# remote WSS javascript clients and local IOT devics.
#
# apps::myIOTServer::Server serves webSockets over the same port
# as the HTTPS Server (6902). Any requests to /ws are
# directed here, and after the handshake is negotiated.
# an endless loop keeps the forked or separate threaded
# process open with the $client (socket) handle lasting
# forever or until a WS close frame, or an inactivity
# timeout.
#
# This technique, of course, should NOT be used with a
# non-forked, non-threaded WebServer.
#
# HANDLE LIMITATION
#
# There is a limit of 65 open handles on Windows.
# Even with workarounds in HTTP::ServerBase, you
# can only open so many myIOT sessions to single
# myIOTServer. This is a known limitation. As long
# as they are correctly closed upon quitting/timing
# out, this seems like a reasonable limitation.
#
#--------------------------------------------------
# 2024-02-19 - separate thread and blocking Thread::Queue
#--------------------------------------------------
# The use of a separate thread and blocking Thread::Queue
# allowed to change this from a polling 100 times a second
# loop into a select can_read() with 2 seconds, signficantly
# reducing server load at a hopefully reasonable cost in memory.


package apps::myIOTServer::WSRemote;
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use Pub::Utils;
use Pub::Prefs;
use Pub::HTTP::Request;
use Pub::HTTP::Response;
use IO::Select;
use Digest::SHA  qw(sha1);
use Protocol::WebSocket::Frame;
use JSON;


my $dbg_wss = 0;
my $dbg_ping = 1;


my $SELECT_TIME = 2.0;
	# The greatest resolution at which PING timeouts
	# can be detected is the number of seconds each
	# socket blocks for reading with select::can_read()


my $ws_thread;
my $in_thread;
my $out_thread;
my $ws_server_num:shared = 0;
my $in_queue = Thread::Queue->new();
my $remotes:shared = shared_clone({});


#-----------------------------------------------
# start and stop API from myIOTServer.pm
#-----------------------------------------------

sub start
{
	display($dbg_wss,0,"WSRemote::start()");
	$in_thread = threads->create(\&in_thread);
	$in_thread->detach();
}



sub stop
{
	display($dbg_wss,0,"WSRemote::stop()");
	enqueueIn(undef,'TERMINATE',1);
}



#---------------------------------------------------
# handle_request() entry point from HTTPServer.pm
#---------------------------------------------------

sub handle_request
	# An HTTPS request to /ws has been made.
	# Attempt to promote it to a WSS Websocket
{
    my ($server,$client,$request) = @_;

	my $fileno = fileno $client;
	display($dbg_wss+1,0,"client sock($client) fileno($fileno)");
	display_hash($dbg_wss+1,0,"request",$request);
	display_hash($dbg_wss+1,0,"headers",$request->{headers});
	display_hash($dbg_wss+1,0,"server default_headers",$request->{server}->{default_headers});

	# There are a number of security requirements upon which
	# we should close the connection and not send anything, or
	# send specific replies.

	my $response;
	my $upgrade = $request->{headers}->{upgrade} || '';
	if ($upgrade && $upgrade eq 'websocket')
	{
		my $key = $request->{headers}->{'sec-websocket-key'};
		warning($dbg_wss,-1,"WS_REMOTE: websocket upgrade requested key=$key");

		my $digest = sha1($key."258EAFA5-E914-47DA-95CA-C5AB0DC85B11"		);
		my $reply_key = encode64($digest);
			# concatenate the client's Sec-WebSocket-Key and the string
			# "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" together,
			# take the SHA-1 hash of the result, and return the base64
			# encoding of that hash.
		my $upgrade_response =
			"HTTP/1.1 101 Switching Protocols\r\n".
			"Upgrade: websocket\r\n".
			"Connection: Upgrade\r\n".
			"Sec-WebSocket-Accept: $reply_key\r\n".
			"\r\n";
		display($dbg_wss+1,0,"reply_key='$reply_key'   digest='$digest'");
		$client->write($upgrade_response);

		$ws_thread = threads->create(\&handle_ws_remote,$client,$request);
		$ws_thread->detach();
		$response = $RESPONSE_STAY_OPEN;
	}
	else
	{
		$response = Pub::HTTP::Response->new($request,
			"unknown upgrade request: $upgrade",
			501,'text/plain');
	}

	return $response;
}





sub handle_ws_remote
	# promoted to Websocket, handle comms from remote javascript UI
{
	my ($sock,$request) = @_;
	my $frame = Protocol::WebSocket::Frame->new();
	$ws_server_num++;

	my $server_num = $ws_server_num;
	my $remote = shared_clone({
		server_num => $server_num,
		pending_out => shared_clone([]),
		out_queue => Thread::Queue->new(),
		num_pings => 0, });
	$remotes->{$server_num} = $remote;

	my $select = IO::Select->new();
	$select->add($sock);

	warning($dbg_wss,-1,"WS_REMOTE($server_num) starting");

	$out_thread = threads->create(\&out_thread,$remote,$sock,$server_num);
	$out_thread->detach();

	# The loop will end under two conditions.
	#
	# (1) a Websocket "close" frame is received, or
	# (2) An inactivity timeout.
	#
	# The javascript MUST implement a heartbeat (i.e. ping) and
	# the INACTIVITY_TIMEOUT must be longer than the javascript interval.
	# And thus, if we don't receive activity every so often, we
	# end the loop and free the socket.

	my $timeout = time();
	my $INACTIVITY_TIMEOUT = 30;
		# currently the javascript client ping time is set to 15 (seconds)

	while (1)
	{
		if (time() > $timeout + $INACTIVITY_TIMEOUT)
		{
			warning($dbg_wss,-1,"==========> WS_REMOTE($server_num) INACTIVITY_TIMEOUT after $remote->{num_pings} pings !!");
			$remote->{num_pings} = 0;
			goto CLOSE_REMOTE;
		}

		if ($select->can_read($SELECT_TIME))
		{
			display($dbg_wss+2,-1,"WS_REMOTE($server_num) can_read()");

			my $buf;
			my $bytes = sysread $sock, $buf, 16384;
			if ($bytes)
			{
				$timeout = time();
				display($dbg_wss+1,-1,"WS_REMOTE($server_num) got $bytes bytes");
				$frame->append($buf);

				while (my $data = $frame->next)
				{
					if ($frame->is_close())
					{
						warning($dbg_wss,-1,"==========> WS_REMOTE($server_num) GOT CLOSE FRAME after $remote->{num_pings} pings !!");
						goto CLOSE_REMOTE;
					}

					# ping handled in tight loop

					if ($data eq '{"cmd":"ping"}')
					{
						# ping does not go through writeRemote to hide debugging
						$remote->{num_pings}++;
						display($dbg_ping,-1,"WS_REMOTE($server_num) got ping, sending pong");
						my $out_frame = Protocol::WebSocket::Frame->new(buffer => '{"pong":1}');
						$sock->write($out_frame->to_bytes());
						next;
					}

					# call json processor

					handle_remote_json($sock,$server_num,$remote,$data);

				}	# while $data
			}	# if $bytes
		}	# can_read
	}	# while (1)


CLOSE_REMOTE:

	warning($dbg_wss,-1,"WS_REMOTE($server_num) disconnected!!!!");

	$remote->{out_queue}->insert(0,'TERMINATE');

	delete $remotes->{$server_num};
	$sock->close();
	Pub::HTTP::ServerBase::endOpenRequest($request);
}



sub handle_remote_json
{
	my ($sock,$server_num,$remote,$json_text) = @_;
	display($dbg_wss,-1,"WS_REMOTE($server_num) handle_remote_json($json_text) device=" . ($remote->{device} ? $remote->{device}->{type} : "undef"));
	my $json = decode_json($json_text);
	if (!$json)
	{
		error("WS_REMOTE($server_num) could not parse json($json_text)");
		return;
	}

	my $cmd = $json->{cmd} || '';
	if ($cmd eq 'set_context')
	{
		my $uuid = $json->{uuid};
		display($dbg_wss,-1,"WS_REMOTE($server_num) setContext($uuid)");
		my $devices = apps::myIOTServer::Device::getDevices();
		my $device = $devices->{$uuid};
		if ($device)
		{
			if ($device->{cache})
			{
				$remote->{device} = $device;
				display_hash($dbg_wss,-1,"WS_REMOTE($server_num) reply",$device->{cache});
				my $text = encode_json($device->{cache});
				display($dbg_wss+1,-1,"WS_REMOTE($server_num) device_list sending ".length($text)." bytes");

				write_ws_remote($sock,$server_num,$text);
			}
			else
			{
				error("WS_REMOTE($server_num) device($device->{type}) has no cache in setContext($uuid)");
			}
		}
		else
		{
			error("WS_REMOTE($server_num) unknown device in setContext($uuid)");
		}
	}
	elsif ($cmd eq 'device_list')
	{
		my $text = '';
		my $devices = apps::myIOTServer::Device::getDevices();
		for my $device (sort {$a->{type} cmp $b->{type}} values %$devices)
		{
			if ($device->{cache})
			{
				$text .= $text ? ",\n" : "\n";
				$text .= '{"uuid":"' . $device->{uuid} . '"';
				$text .= ',"name":"' . $device->{cache}->{device_name} . '"}';		# should be {cache}->{device_name}
			}
			else
			{
				warning(0,0,"device($device->{type}) has no cache in device_list");
			}
		}
		$text = '{"device_list":[' . $text . ']}';
		write_ws_remote($sock,$server_num,$text);
	}
	elsif ($remote->{device})
	{
		display($dbg_wss,-1,"WS_REMOTE($server_num) dispatching $json_text to $remote->{device}->{type}");
		$remote->{device}->writeLocal($json_text);
	}
}


#-------------------------------------------------
# lower level utilities
#-------------------------------------------------

sub write_ws_remote
{
	my ($sock,$server_num,$buf) = @_;
	display($dbg_wss+1,0,"WS_REMOTE($server_num) write_ws_remote(".length($buf).")");
	my $frame = Protocol::WebSocket::Frame->new(buffer => $buf);
	my $data = $frame->to_bytes();
	$sock->write($data);
	# my $len = length($data);
	# my $fileno = fileno $sock
	# display($dbg_wss+1,1,"sock($sock) fileno($fileno) frame length=$len");
	# my $select = IO::Select->new($sock);
	# my $can_read = $select->can_read(0.001) ? 1 : 0;
	# my $can_write = $select->can_write(0.001) ? 1 : 0;
	# my $exception = $select->has_exception (0.001) ? 1 : 0;
	# my $pending = $sock->pending() || 0;
	# display(0,0,"pending($pending) can_read($can_read) can_write($can_write) exception($exception)");
	# my $rslt = syswrite($sock,$data,$len);
	# display($dbg_wss+1,1,"writeRemote() wrote($rslt/$len) bytes");
}


sub out_thread
	# started for each socket, dequeues straight
	# message from the remote's out_queue and writes
	# to the client socket.
{
	my ($remote,$sock,$server_num) = @_;
	display($dbg_wss,0,"WSRemote::out_thread($server_num) started");
	while (1)
	{
		my $pending = $remote->{out_queue}->dequeue();
		goto END_OUT_THREAD if $pending eq 'TERMINATE';
		while ($pending)
		{
			display($dbg_wss+1,0,"QUEUE WS_REMOTE($remote->{server_num}) dequeued "._lim($pending,40));
			write_ws_remote($sock,$server_num,$pending);
			$pending = $remote->{out_queue}->dequeue_nb();
			goto END_OUT_THREAD if $pending && $pending eq 'TERMINATE';
		}
	}

END_OUT_THREAD:
	display($dbg_wss,0,"WSRemote::out_thread($server_num) terminating");

}


sub in_thread
	# the thread for the input queue handling
	# dequeues global device:msgs requests and
	# re-enques them on the out_queue of any
	# remotes looking at that device.
{
	display($dbg_wss,0,"WSRemote::in_thread() started");

	while (1)
	{
		my $packet = $in_queue->dequeue();
		goto END_IN_THREAD if $packet->{msg} eq 'TERMINATE';

		while ($packet)
		{
			my $msg = $packet->{msg};
			my $device = $packet->{device};
			if ($msg)
			{
				display($dbg_wss+1,0,"in_thread requeuing($device->{uuid}) "._lim($msg,40));
				for my $remote (values %$remotes)
				{
					$remote->{out_queue}->enqueue($msg)
						if $remote->{device} &&
						   $device->{uuid} eq $remote->{device}->{uuid};
				}
			}
			$packet = $in_queue->dequeue_nb();
			goto END_IN_THREAD if $packet && $packet->{msg} eq 'TERMINATE';
		}
	}
END_IN_THREAD:

	display($dbg_wss,0,"WSRemote::in_thread() terminating");
}



#--------------------------------------------------
# API - called from Device.pm
#--------------------------------------------------

sub enqueueIn
	# public
	# called by the device to send a message to all wSRemotes
	# that *might* be connected to it. use undef,'TERMINATE',1
	# to stop the in_thread();
{
	my ($device,$msg,$at_start) = @_;
	$at_start ||= 0;
	display($dbg_wss+1,0,"eneuqueIn($at_start,".($device?$device->{type}:'undef')." )msg="._lim($msg,40));
	my $packet = shared_clone({
		device => $device,
		msg	   => $msg });
	$at_start ?
		$in_queue->enqueue($packet) :
		$in_queue->insert(0,$packet);
}



sub removeDeviceQueue
	# public
	# called by device when it goes offline.
	# effectively remove a device from the queue
	# by setting all of it's msgs, if any, to ''
{
	my ($remove_device) = @_;
	my $uuid = $remove_device->{uuid};
	display($dbg_wss,0,"removeDeviceQueue($uuid)");

	my $index = 0;
	my $packet = $in_queue->peek($index++);
	while ($packet)
	{
		my $device = $packet->{device};
		$packet->{msg} = '' if
			$device &&
			$device->{uuid} eq $uuid;
		$packet = $in_queue->peek($index++);
	}

}




1;
