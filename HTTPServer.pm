#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT:HTTPServer.pm
#-----------------------------------------------------
# The HTTP Server for my IOT Server running on the rPi

use lib '/base';
	# needed for unix service

package apps::myIOTServer::myIOTServer;		# continued
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use Pub::Utils;
use Pub::Prefs;
use Pub::ServiceUpdate;
use Pub::HTTP::Response;
use Pub::HTTP::ServerBase;
use apps::myIOTServer::Device;
use base qw(Pub::HTTP::ServerBase);


my $dbg_server = 1;
my $dbg_fwd = 0;


#---------------------------------------------------------
# handle_request
#---------------------------------------------------------

sub handle_request
	# At this point they are logged with a valid HTTP basicAuth header that
	# has been confirmed against the user names and passwords in users.txt.
	# apps::myIOTServer::Serverbase has added "auth_user" and "auth_privs" fields with
	# the "privs" from that user file.
    #
	# $request->{auth_priv}, availalbe for use, is a comma delimited list
	# of pid:level where pid is a program id. The priv *:5 is reserved
	# for me for all programs at security level 5
{
    my ($this,$client,$request) = @_;
	my $uri = $request->{uri};
	my $method = $request->{method};

	my $response;

	# now standard in base_class
	# my $auth_privs = $request->{auth_privs} || '';
	# my $save_login = $login_name;
	# $login_name = $request->{auth_user} || '';

    display($dbg_server,0,"handle_request($method,$uri)");

	#------------------------------------
	# external stuff
	#------------------------------------
	# Handle pass-thru requests to devices

	if ($method eq 'POST' &&
		$uri =~ /^\/(ota_files)/ ||
		$uri =~ /^\/(spiffs_files)/ ||
		$uri =~ /^\/(sdcard_files)/)
	{
		my $kind = $1;
		display_hash($dbg_fwd+1,-1,"headers",$request->{headers});
		my $uuid = $request->{headers}->{'x-myiot-deviceuuid'};
		return http_error($request,"No UUID header in $kind $request->{method} request")
			if !$uuid;
		$response = forwardRequest($client,$request,$kind,$uuid);
	}
	elsif ($method eq 'GET' &&
		 $uri =~ /^\/(custom)\// ||
		 $uri =~ /^\/(sdcard)\// ||
		 $uri =~ /^\/(spiffs)\//)
	{
		my $kind = $1;
		my $params = $request->{params};
		my $uuid = $params->{uuid};
		return http_error($request,"No UUID header in $kind $request->{method} request")
			if !$uuid;
		$response = forwardRequest($client,$request,$kind,$uuid);
	}

	#---------------------------------------------
	# file_server functions
	#---------------------------------------------

	elsif ($uri =~ /^\/file_server\/(.*)$/)
	{
		my $what = $1;
		my $filelog = "/base_data/temp/fileServer/fileServer.log";
		if ($what eq 'log')
		{
			$response = Pub::HTTP::Response->new($request,
				shared_clone({filename=>$filelog}),
				200,'text/plain');
		}
		elsif ($what eq 'log/clear')
		{
			unlink $filelog;
			my $save_logfile = $logfile;
			$logfile = $filelog;
			LOG(0,"filelog $filelog cleared");
			$logfile = $save_logfile;
			$response = Pub::HTTP::Response->new($request,
				shared_clone({filename=>$filelog}),
				200,'text/plain');
		}
		elsif ($what =~ /^(stop|start|restart)$/)
		{
			my $msg = "myIOTServer $what the fileServer service";
			LOG(0,'file_server '.$msg);
			system("sudo systemctl $what fileServer");
			$response = http_ok($request,$msg);
		}
		elsif ($what =~ /^forward_(start|stop)$/)
		{
			LOG(0,"file_server forward $what");
			set_FS_DO_FORWARD($what eq 'forward_start' ? 1 : 0);
			system("sudo systemctl restart fileServer");
			$response = http_ok($request,"myIOTServer performed fileServer $what");
		}
	}


	#---------------------------------------------------------
	# Promote the remote request to a WebSocket
	#---------------------------------------------------------

	elsif ($uri eq "/ws")
	{
		$response = apps::myIOTServer::WSRemote::handle_request($this,$client,$request);
	}


	#-------------------------------------------
	# experiments
	#-------------------------------------------

	elsif ($uri eq '/get_device_widgets')
	{
		my $devices = apps::myIOTServer::Device::getDevices();
			# the key is the uuid of the device.
			# interesting fields:
			#	uuid
			#	version
			#	type
			#	cache->
			#		device_name					"fridgeController"
			#		device_widget->
			#			onInactivate:			"stopChart('fridgeData')"
			#			onActivate				"doChart('fridgeData')"
			#			html
			#
			#				 <div id='fridgeData'>
			#				 	<div id='fridgeData_chart' class='iot_chart'></div>
			#				 	&nbsp;&nbsp;&nbsp;
			#				 	<button id='fridgeData_update_button' onclick="doChart('fridgeData')" disabled>Update</button>
			#				 	&nbsp;&nbsp;&nbsp;
			#				 	<label for='fridgeData_chart_period'>Chart Period:</label>
			#				 	<select name='period' id='fridgeData_chart_period' onchange="get_chart_data('fridgeData')">
			#				 		<option value='0'>All</option>
			#				 		<option value='60'>Minute</option>
			#				 		...
			#				 		<option value='86400' selected='selected'>Day</option>
			#				 		...
			#				 		<option value='7776000'>3 Months</option>
			#				 		<option value='31536000'>Year</option>
			#				 	</select>
			#				 	&nbsp;&nbsp;&nbsp;
			#				 	<label for='fridgeData_refresh_interval'>Refresh Interval:</label>
			#				 	<input id='fridgeData_refresh_interval' type='number' value='0' min='0' max='999999'>
			#				 </div>
			#
			#			name:					fridgeWidget
			#			dependencies:			comma delimited list of href portions of dependencies
			#
			#		the "name" should be "fridgeData", and THAT should be sufficient
			#		to create the onInactivate and Activate calls.
			#
			# Have to think about this a bit.
			# A "widget" is NOT a chart, although a device's widget may primarily be a chart.
			# A widget is a small html-ish summary of the state of the device, perhaps with specific
			# 		values and formats and new display characteristics, that *may* include a chart
			#		or plot as part of the presentation.



		my $new_devices = {};
		for my $device (values %$devices)
		{
			my $uuid = $device->{uuid};

			my $new_device = {};
			$new_devices->{$uuid} = $new_device;

			$new_device->{uuid} = $uuid;
			$new_device->{device_name} = $device->{cache}->{device_name};
			$new_device->{device_widget} = $device->{cache}->{device_widget};
		}

		use Data::Dumper;
		$Data::Dumper::Indent = 1;
		$Data::Dumper::Sortkeys = 1;
		print "\n-------------------------DEVICES -------------------------------\n";
		print Dumper($new_devices);
		print "\n-----------------------------------------------------------\n";
		$response = json_response($request,$new_devices);
	}


	#------------------------------------
	# Base Class Stuff
	#------------------------------------
	# base class handles /reboot, /shutdown_system, /restart_service,
	# /update_system(_stash) # and static files

	else
	{
		$response = Pub::HTTP::ServerBase::handle_request($this,$client,$request);
	}

	# $login_name = $save_login;
	return $response;
}



#-----------------------------------------------
# forwardRequest
#-----------------------------------------------
# Forward certain GET and POST requests to specific device (by uuid).
# We HAVE to rebuild the GET query parameters onto the URI as
#	they were stripped off by the base HTTPServer. Although I
#   am not aware of any use of query params on POST requests,
#   we might also need to rebuild them onto POST requests.
# We then send the a subset of the original request headers to the
#   device. The use of a subset decreases the traffic and/or *may*
#	be required perhaps to get them in a specific order. But it
#	also might be easier to just send them all.
#
# We then receive bytes from the device and send them to the client.
# The current working code assumes the headers will come in a single recv() call.
#
# We then loop, forwarding 10K buffers of content from the device
# 	to the client.
# For well formed responses (with a content-length) we can send
# exactly the whole response back to the client, but for certain
# (chunked) responses, like the one for chart_data of unknown length,
# we have depend on sysread() returning 0 when the content is finished.


sub forwardRequest
	# this might be something that is limited by auth_privs
{
	my ($client,$request,$kind,$uuid) = @_;

	# find the device

	my $device = apps::myIOTServer::Device::findDeviceByUUID($uuid);
	if (!$device)
	{
		error("Could not find device($uuid) in $kind $request->{method} request");
		return undef;
	}
	warning($dbg_fwd,0,"forwarding $kind $request->{method} request to $device->{type} at $device->{ip}:$device->{port}");

	# open the socket

	my $sock = IO::Socket::INET->new("$device->{ip}:$device->{port}");
	if (!$sock)
	{
		error("Could not open connection to $device->{type} at $device->{ip}:$device->{port}");
		return;
	}

	# magic copied from apps::myIOTServer::Message.pm

    local $/ = Socket::CRLF;
	binmode $sock;
	$sock->autoflush(1);

	# rebuild GET query parameters

	my $param_str = '';
	if ($request->{method} eq 'GET')
	{
		my $params = $request->{params};
		for my $key (sort keys(%$params))
		{
			my $val = $params->{$key};
			$param_str .= $param_str?"&":"?";
			$param_str .= "$key=$val";
		}
	}

	my $uri = $request->{uri};
	my $headers = $request->{headers};
	my $text = "$request->{method} $uri$param_str HTTP/1.1\r\n";

	# send certain headers
	#
	# accept = '*/*'
	# accept-encoding = 'gzip, deflate, br'
	# accept-language = 'en-US,en;q=0.5'
	# authorization = 'Basic cHJoOnByaDEzNHg='
	# connection = 'keep-alive'
	# content-length = '5271'
	# content-type = 'multipart/form-data; boundary=---------------------------154764450822490360233068143126'
	# dnt = '1'
	# host = 'localhost:6902'
	# origin = 'https://localhost:6902'
	# referer = 'https://localhost:6902/index.html'
	# sec-fetch-dest = 'empty'
	# sec-fetch-mode = 'cors'
	# sec-fetch-site = 'same-origin'
	# user-agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0'
	# x-myiot-deviceuuid = '38323636-4558-4dda-9188-7c9ebd667ddc'

	$text .= "Host: $headers->{host}\r\n";
	$text .= "Content-Type: $headers->{'content-type'}\r\n"
		if $headers->{'content-type'};
	$text .= "Content-Length: $headers->{'content-length'}\r\n"
		if $headers->{'content-length'};
	$text .= "Accept-Encoding: $headers->{'accept-encoding'}\r\n"
		if $headers->{'accept-encoding'};
	$text .= "\r\n";

	display($dbg_fwd+1,0,"Sending HEADERS\n$text");
	$sock->write($text);

	# send the content (for POST requests)

	my $content = $request->{content};
	display($dbg_fwd+1,0,"Sending ".length($content)." bytes of CONTENT");
	$sock->write($content);

	#--------------------------------
	# read and forward the response
	#--------------------------------
	# There is some kind of issue simply using the <$sock> form of reading
	# lines of text.   When I do sysreads of custom chart_header I get the
	# content type, but when I do <$sock> I don't !!

	my $content_length = -1;
	display($dbg_fwd+1,0,"waiting for result");

	if (1)	# working code, do a single recv() call to get all headers
	{
		my $buf;
		my $rslt = $sock->recv($buf,10000);
		if (length($buf))
		{
			display_bytes($dbg_fwd+1,0,"got headers",$buf);
			$client->write($buf);
			$content_length = $1 if $buf =~ /Content-Length: (\d+)/;
		}
	}

	else	# OLD CODE: use <$sock> form to read headers
	{
		# wasn't working on chart_header for some reason ?!?
		# never got/forwarded the application/json header
		while (my $line = <$sock>)
		{
			$client->write($line);
			$line =~ s/\s$//g;
			display($dbg_fwd+1,1,"forwarded header_line: $line");
			$content_length = $1 if $line =~ /Content-Length: (\d+)$/;
			last if !$line;
			$line = <$sock>;
		}
	}


	# forward the content, if any, to the client
	# content length of -1 indicates chunked response (no known length)

	if ($content_length)
	{

		display($dbg_fwd,0,$content_length > 0?
			"forwarding $content_length bytes of content" :
			"forwarding unknown number of bytes of (chunked) content");

		my $TIMEOUT = 60;
		
		my $buf;
		my $remain = $content_length;
		my $timeout = time();
		while ($remain)
		{
			if (time() > $timeout + $TIMEOUT)
			{
				error("read timed out");
				last;
			}
			my $to_read = $remain > 0 ? $remain : 10000;
			$to_read = 10000 if $to_read > 10000;
			my $got = sysread $sock,$buf,$to_read;
			if ($got != $to_read)
			{
				# we often receive less than we asked for while it still works.
				# 	warning(0,0,"forwarding read expected $to_read got $got");
				# however, if we receive nothing, it means that a chunked response is done.

				if (!$got)
				{
					warning($dbg_fwd,0,"forward sysread returned zero");
					last;
				}
				$to_read = $got;
			}

			# write the buffer to the client

			if ($to_read)
			{
				$timeout = time();
				$got = syswrite $client,$buf,$to_read;
				if ($got != $to_read)
				{
					error("forwarding write expected $to_read got $got");
					last;
				}
				$remain -= $to_read if $remain > 0;
			}
		}
	}

	display($dbg_fwd,0,"forwardRequest() returning");
	return $RESPONSE_HANDLED;;
}



#-----------------------------------------------------------
# pseudo prefs routines for fileServer from myIOTServer
#-----------------------------------------------------------

my $fs_prefs_filename = '/base_data/data/fileServer/fileServer.prefs';
	# hardwired

sub getFS_DO_FORWARD
{
	my $retval = 0;
	my @lines = getTextLines($fs_prefs_filename);
	for my $line (@lines)
	{
		if ($line =~ /^\s*FS_DO_FORWARD\s*=\s*(\d)/)
		{
			$retval = $1;
			last;
		}
	}
	LOG(0,"get_FS_DO_FORWARD()=$retval");
	return $retval;
}


sub set_FS_DO_FORWARD
{
	my ($fwd) = @_;
	LOG(0,"set_FS_DO_FORWARD($fwd)");
	my $text = '';
	my @lines = getTextLines($fs_prefs_filename);
	my $gotit = 0;
	for my $line (@lines)
	{
		if ($line =~ /^\s*FS_DO_FORWARD\s*=\s*(\d)/)
		{
			$line = "FS_DO_FORWARD = $fwd";
			$gotit = 1;
		}
		$text .= $line."\n";
	}
	$text .= "\nFS_DO_FORWARD = $fwd\n"
		if !$gotit;
	printVarToFile(1,$fs_prefs_filename,$text);
}



1;
