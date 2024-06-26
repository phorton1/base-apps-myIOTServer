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
		my $fs_logfile = "/base_data/temp/fileServer/fileServer.log";
		if ($what eq 'log')
		{
			$response = Pub::HTTP::Response->new($request,
				shared_clone({filename=>$fs_logfile}),
				200,'text/plain');
		}
		elsif ($what eq 'log/clear')
		{
			unlink $fs_logfile;
			my $save_logfile = $logfile;
			$logfile = $fs_logfile;
			LOG(0,"fs_logfile $fs_logfile cleared");
			$logfile = $save_logfile;
			$response = Pub::HTTP::Response->new($request,
				shared_clone({filename=>$fs_logfile}),
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

	# send the headers
	# We send out mimimal headers, however, here's what we received (not in order)
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

	my $uri = $request->{uri};
	my $headers = $request->{headers};
	my $text = "$request->{method} $uri HTTP/1.1\r\n";
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

	# send the content

	my $content = $request->{content};
	display($dbg_fwd+1,0,"Sending ".length($content)." bytes of CONTENT");
	$sock->write($content);

	# get reply headers nad forward them to the client

	display($dbg_fwd+1,0,"waiting for result");
	my $content_length = 0;
	while (my $line = <$sock>)
	{
		$client->write($line);
		$line =~ s/\s$//g;
		display($dbg_fwd+1,1,"forwarded header_line: $line");
		$content_length = $1 if $line =~ /Content-Length: (\d+)$/;
		last if !$line;
		$line = <$sock>;
	}

	# forward the content, if any, to the client

	if ($content_length)
	{
		display($dbg_fwd,0,"forwarding $content_length bytes of content");

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
			my $to_read = $remain;
			$to_read = 10000 if $to_read > 10000;
			my $got = sysread $sock,$buf,$to_read;
			if ($got != $to_read)
			{
				# we often receive less than we asked for while it still works.
				# warning(0,0,"forwarding read expected $to_read got $got");
				if (!$got)
				{
					error("sysread returned zero");
					last;
				}
				$to_read = $got;
			}

			# write a buffer to the client

			if ($to_read)
			{
				$timeout = time();
				$got = syswrite $client,$buf,$to_read;
				if ($got != $to_read)
				{
					error("forwarding write expected $to_read got $got");
					last;
				}
				$remain -= $to_read;
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
