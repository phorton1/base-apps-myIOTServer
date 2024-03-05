#!/usr/bin/perl
#-----------------------------------------------------
# apps::myIOTServer::IOTServer.pm
#-----------------------------------------------------
# The Server for my IOT Server running on the rPi


package apps::myIOTServer::myIOTServer;
	# continued in apps::myIOTServer::HTTPServer.pm
use strict;
use warnings;
use threads;
use threads::shared;
use Sys::MemInfo;
use Time::HiRes qw(sleep);
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Pub::Utils;
use Pub::Prefs;
use Pub::DebugMem;
use Pub::ServerUtils;
use Pub::ServiceMain;
use Pub::PortForwarder;
use Pub::HTTP::ServerBase;
use apps::myIOTServer::Device;
use apps::myIOTServer::HTTPServer;
use apps::myIOTServer::Searcher;
use apps::myIOTServer::Wifi;
use apps::myIOTServer::WSLocal;
use apps::myIOTServer::WSRemote;
use base qw(Pub::HTTP::ServerBase);


my $dbg_main = 0;

my $IOT_SERVER_PORT = 6902;


our $last_connected = 0;


#--------------------------------------
# HTTPS Server start method
#--------------------------------------

my $https_server;

sub startHTTPS
{
	# because there is a preference file, we do NOT
	# pass in many parameters.  They can explicity
	# be added to $params here to override anything from
	# the prefs file.

	# Otherwise, we set some defaults here, which can
	# be overriden in the prefs file.

	my $params = {};

	getObjectPref($params,'HTTP_SERVER_NAME',	'myIOTServer('.getMachineId().')');

	getObjectPref($params,'HTTP_PORT',			$IOT_SERVER_PORT);
	getObjectPref($params,'HTTP_SSL',			1);
	getObjectPref($params,'HTTP_SSL_CERT_FILE',	"/base_data/_ssl/myIOTServer.crt");
	getObjectPref($params,'HTTP_SSL_KEY_FILE',	"/base_data/_ssl/myIOTServer.key");
	getObjectPref($params,'HTTP_AUTH_FILE',		"$data_dir/users.txt");
	getObjectPref($params,'HTTP_AUTH_REALM',	"myIOTServer");
	getObjectPref($params,'HTTP_DOCUMENT_ROOT',	"/base/apps/myIOTServer/site");
	getObjectPref($params,'HTTP_DEFAULT_LOCATION',"/myIOT/index.html");

	getObjectPref($params,'HTTP_ALLOW_REBOOT',   1);			# linux only
	getObjectPref($params,'HTTP_RESTART_SERVICE','myIOTServer');
	getObjectPref($params,'HTTP_GIT_UPDATE',     '/base/Pub,/base/apps/myIOTServer,/base/apps/myIOTServer/site/myIOT');
		# added simplistic attempt to update submodules

	$https_server = apps::myIOTServer::myIOTServer->new($params);
	$https_server->start();
}


#------------------------------------------
# start and stop everything
#------------------------------------------

sub stopEverything
{
	LOG(-1,"Stopping Searcher");
	apps::myIOTServer::Searcher::stop();
	LOG(-1,"Searcher STOPPED");

	if ($https_server)
	{
		LOG(-1,"stopping HTTPS Server");
		$https_server->stop();
		$https_server = undef;
		LOG(-1,"HTTPS Server STOPPED");
	}

	LOG(-1,"Stopping WSRemote");
	apps::myIOTServer::WSRemote::stop();

	LOG(-1,"Stopping WSLocal");
	apps::myIOTServer::WSLocal::stop();
}


sub startEverything
{
	apps::myIOTServer::WSLocal::start();	# nop
	apps::myIOTServer::WSRemote::start();

	# Should be a check on the success of starting the HTTPS server
	# and if it doesn't work, bail and re-schedule the whole thing.

	startHTTPS();
	while (!apps::myIOTServer::Searcher::start(\&apps::myIOTServer::Device::add))
	{
		display(0,0,"waiting 3 seconds to restry starting Searcher");
		sleep(3);
	}
}


#-------------
# Begin
#-------------

$login_name = '';

my $program_name = 'myIOTServer';

setStandardTempDir($program_name);
	# /base_data/temp/myIOTServer
setStandardDataDir($program_name);
	# /base_data/data/myIOTServer

$logfile = "$temp_dir/$program_name.log";

Pub::Utils::initUtils(1,0);
	# 1 == AS_SERVICE
	# 0 == QUIET
Pub::ServerUtils::initServerUtils(1,"$temp_dir/$program_name.pid");
	# 1 == NEEDS WIFI
	# '' == LINUX PID FILE

display($dbg_main,0,"----------------------------------------------");
display($dbg_main,0,"$program_name.pm starting");
display($dbg_main,0,"----------------------------------------------");

$SIG{CHLD} = 'DEFAULT' if !is_win();
	# needed to run git in ServiceUpdate.pm from backticks
	# must be called after initServerUtils, which sets it to
	# IGNORE when spawning the initial unix service


Pub::Prefs::initPrefs(
	"$data_dir/$program_name.prefs",
	{},
	"/base_data/_ssl/PubCryptKey.txt");

LOG(-1,"myIOTServer started ".($AS_SERVICE?"AS_SERVICE":"NO_SERVICE")."  server_ip=$server_ip");

# Start the Wifi Monitor and Wait for Wifi to Start
# This is already done by initServerUtils, but we monitor the wifi

my $wifi_count = 0;
apps::myIOTServer::Wifi::start();
while (!apps::myIOTServer::Wifi::connected())
{
	display(0,0,"Waiting for wifi connection ".$wifi_count++);
	sleep(1);
}


#--------------------------------------
# Main
#--------------------------------------

my $MEMORY_REFRESH = 7200;		# every 2 hours
my $memory_time = 0;


sub on_loop
{
	my $connected = apps::myIOTServer::Wifi::connected();
		# set by separate thread that runs every 2 seconds

	if ($last_connected != $connected)
	{
		$last_connected = $connected;
		if ($last_connected)
		{
			sleep(5);
			startEverything();
			debug_memory("at start");
		}
		else
		{
			stopEverything();
			# sleep(5);
		}
	}

	# we check once a second for devices that
	# to need to be reconnected (WS_LOCAL)

	elsif ($last_connected)
	{
		apps::myIOTServer::Device::loop();
	}

	# and every so often we output the memrory

	my $now = time();
	if ($MEMORY_REFRESH && ($now > $memory_time + $MEMORY_REFRESH))
	{
		$memory_time = $now;
		debug_memory("in loop");
	}
}



sub on_terminate()
{
	stopEverything();
	sleep(1);
	return 0;
}


# The main loop and program uses very little CPU on either machine

Pub::ServiceMain::main_loop({
	MAIN_LOOP_CONSOLE => 1,
	MAIN_LOOP_SLEEP => 0.2,		# most programs use 0.2
	MAIN_LOOP_CB_TIME => 1,		# most programs use 1 minimum
	MAIN_LOOP_CB => \&on_loop,
	# MAIN_LOOP_KEY_CB => \&on_console_key,
	MAIN_LOOP_TERMINATE_CB => \&on_terminate,
});


# never gets here


1;
