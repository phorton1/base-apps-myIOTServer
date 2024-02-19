#!/usr/bin/perl
#-----------------------------------------------------
# apps::myIOTServer::WSLocal.pm
#-----------------------------------------------------
# WSLocal is the object that handles persistent
# WebSocket connections to local myIOT devices.
#
# There is a zero or one to one correspondence
# of these WSLocal's with Devices.
#
# It works in conjunction with Devices and
# the WSRemote to channel requests between external
# remote WSS javascript clients and local IOT devics.

package apps::myIOTServer::WSLocal;
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use Pub::Utils;
use Pub::Prefs;
use IO::Select;
use Protocol::WebSocket::Client;


my $dbg_local = 0;
my $dbg_ping = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
	);
}


my $SELECT_TIME = 2;
my $CLIENT_PING_INTERVAL = 15;
my $CLIENT_PING_TIMEOUT = 7;



my $stopping:shared = 0;
my $local_num:shared = 1;
my $local_websockets = shared_clone({});
my $local_thread;
my $out_thread;



#-----------------------------------------------
# start and stop API from myIOTServer.pm
#-----------------------------------------------


sub start()
{
	display($dbg_local,0,"WSLocal::start()");
}


sub stop()
{
	display($dbg_local,0,"WSLocal::stop()");
	$stopping = 1;
}



#----------------------------------------------------
# entry point from device
#----------------------------------------------------

sub open
{
	my ($device) = @_;
	display($dbg_local,0,"WSLocal::open device($local_num,$device->{type}) $device->{uuid}");

	my $local_ws = shared_clone({
		num => $local_num,
		device => $device,
		out_queue => Thread::Queue->new(), });

	$local_websockets->{$local_num++} = $local_ws;
	$local_thread = threads->create(\&local_thread,$local_ws);
	$local_thread->detach();
}


sub local_thread
{
	my ($local_ws) = @_;
	my $device = $local_ws->{device};
	my $local_num = $local_ws->{num};
	my $ip = $device->{ip};
	my $port = $device->{port}+1;
	display($dbg_local,0,"WS_LOCAL($local_num) local_thread($device->{type}) $device->{uuid} at $ip:$port");

	my $ws_client = Protocol::WebSocket::Client->new(
		url => "ws://#ip:$port");

	if (!$ws_client)
	{
		error("Could not open ws_client(ws:://$ip:$port)");
		return;
	}
	display($dbg_local+2,1,"WS_LOCAL::open($local_num) client_created $ws_client");

	$ws_client->on( write => \&on_write );
	$ws_client->on( read => \&on_read );
	$ws_client->on( connect => \&on_connect );
	$ws_client->on( eof => \&on_eof );
	$ws_client->on( error => \&on_error );

	# open the socket with the protcol in place

	my $ws_socket = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => "ws($port)",
		Proto => 'tcp',
		Blocking => 1 );

	if (!$ws_socket)
	{
		error("Could not open ws_socket($ip:$port)");
		return;
	}
	display($dbg_local+2,1,"WS_LOCAL::open($local_num) socket opened $ws_socket");

	$ws_client->{ws_socket} = $ws_socket;
	$ws_client->{device} = $device;
	$ws_client->{local_num} = $local_num;
	$ws_client->{pong_time} = time();
	$ws_client->{ping_time} = 0;
	$ws_client->{pong_count} = 0;

	$out_thread = threads->create(\&out_thread,$local_ws,$ws_client);
	$out_thread->detach();

	$device->onOpen($local_num);
	$ws_client->connect();

	display($dbg_local+1,1,"WS_LOCAL($local_num) opened to $device->{type} at $ip:".($port+1));

	my $select = IO::Select->new();
	$select->add($ws_socket);

	while (1)
	{
		goto END_LOCAL_THREAD if $stopping;

		if ($select->can_read($SELECT_TIME))
		{
			my $buf;
			my $bytes = sysread $ws_socket, $buf, 16384;
			goto END_LOCAL_THREAD if $stopping;
			if ($bytes)
			{
				display($dbg_local+1,0,"got $bytes bytes for WS_REMOTE($local_num)");
				$ws_client->read($buf);
			}
		}
		if ($ws_client->{ping_time} &&
			time() > $ws_client->{ping_time} + $CLIENT_PING_TIMEOUT)
		{
			warning(0,-1,"WS_LOCAL($local_num),$device->{type}) PING TIMEOUT after $ws_client->{pong_count} pongs!");;
			goto END_LOCAL_THREAD;
		}

		# send a ping

		elsif (!$stopping &&
			   !$ws_client->{ping_time} &&
			   time() > $ws_client->{pong_time} + $CLIENT_PING_INTERVAL)
		{
			my $tm = time();
			display($dbg_ping,0,"WS_LOCAL($local_num,$device->{type}) Sending ping at $tm");
			$ws_client->{ping_time} = $tm;
			$ws_client->write('{"cmd":"ping"}');
		}
	}


END_LOCAL_THREAD:

	display($dbg_local,0,"WS_LOCAL($local_num) local_thread() terminating");
	$local_websockets->{$local_num}->insert(0,'TERMINATE');
	delete $local_websockets->{$local_num};
	$ws_client->{ping_time} = 0;
	$ws_client->{pong_count} = 0;
	$ws_client->disconnect();
	$ws_client->{device}->onClose();

}


sub on_write
{
	my ($ws_client,$buf) = @_;
	display($dbg_local+1,0,"WS_LOCAL($ws_client->{local_num},$ws_client->{device}->{type}) on_write() bytes=".length($buf));
	syswrite($ws_client->{ws_socket}, $buf);
}

sub on_read
{
    my ($ws_client,$buf) = @_;
	if ($buf eq '{"pong":1}')
	{
		display($dbg_ping,0,"WS_LOCAL($ws_client->{local_num},$ws_client->{device}->{type}) got pong");
		$ws_client->{ping_time} = 0;
		$ws_client->{pong_time} = time();
		$ws_client->{pong_count}++;
		return;
	}
	display($dbg_local+1,0,"WS_LOCAL($ws_client->{local_num},$ws_client->{device}->{type}) on_read() bytes=".length($buf));
	# print $buf."\n";
	$ws_client->{device}->onLocal($buf);
}


sub on_connect
{
	my ($ws_client) = @_;
	warning($dbg_local,0,"WS_LOCAL($ws_client->{local_num},$ws_client->{device}->{type}) on_connect()");

	# send the standard setup requests to the device
	# to build the in-memory read-thru cache

	$ws_client->write('{"cmd":"device_info"}');
	$ws_client->write('{"cmd":"value_list"}');
	$ws_client->write('{"cmd":"spiffs_list"}');
	$ws_client->write('{"cmd":"sdcard_list"}');
}


sub on_eof
{
	my ($ws_client) = @_;
	error("WS_LOCAL($ws_client->{client_num},$ws_client->{device}->{type}) on_eof");
}

sub on_error
{
	my ($ws_client,$error) = @_;
	error("WS_LOCAL($ws_client->{local_num},$ws_client->{device}->{type}) on_error=$error)");
}


#-----------------------------------
# out_thread
#-----------------------------------


sub out_thread
	# started for each socket, dequeues straight
	# message from the remote's out_queue and writes
	# to the client socket.
{
	my ($local_ws,$ws_client) = @_;
	my $local_num = $local_ws->{num};
	display($dbg_local,0,"WSLocal::out_thread($local_num) started");
	while (1)
	{
		my $pending = $local_ws->{out_queue}->dequeue();
		goto END_OUT_THREAD if $pending eq 'TERMINATE';
		while ($pending)
		{
			display($dbg_local+1,0,"WS_LOCAL($local_num) dequeued "._lim($pending,40));
			$ws_client->write($pending);
			$pending = $local_ws->{out_queue}->dequeue_nb();
			goto END_OUT_THREAD if $pending && $pending eq 'TERMINATE';
		}
	}

END_OUT_THREAD:
	display($dbg_local,0,"WSLocal::out_thread($local_num) terminating");

}



#-----------------------------------
# API
#-----------------------------------

sub enqueueOut
{
	my ($local_num,$msg) = @_;
	display($dbg_local,0,"WS_LOCAL($local_num) writeLocal()"._lim($msg,40));
	my $local_ws = $local_websockets->{$local_num};
	if ($local_ws)
	{
		$local_ws->{out_queue}->enqueue($msg);
	}
	else
	{
		error("Could not find local_websocket($local_num)");
	}

}



1;
