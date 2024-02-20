//--------------------------------------------
// admin.js
//--------------------------------------------

var cur_button = 'dashboard_button';

function onTab(event)
    // triggered when the user changes tabs in the UI
{
    cur_button = event.target.id;
    $('#status1').html(cur_button);
    if (cur_button == 'logfile_button')
        logfile('/log');
    if (cur_button == 'fs_logfile_button')
        fs_logfile('/log');
}


//---------------------------------
// log files
//---------------------------------

function logfile(what)
{
    $('#status2').html(what);
    httpRequest(what,onLogReceived,httpError,httpTimeout);
}
function onLogReceived()
{
    $('#logfile_content').html(this.responseText);
    setTimeout(function () {
        window.scroll({
            top: $('#logfile_div')[0].scrollHeight,
            left: 0,
            behavior: 'auto'    // smooth'
          });
    },100);
}

function fs_logfile(what)
{
    $('#status2').html(what);
    httpRequest('file_server' + what,onFSLogReceived,httpError,httpTimeout);
}
function onFSLogReceived()
{
    $('#fs_logfile_content').html(this.responseText);
    setTimeout(function () {
        window.scroll({
            top: $('#fs_logfile_div')[0].scrollHeight,
            left: 0,
            behavior: 'auto'    // smooth'
          });
    },100);
}


//---------------------------------
// reboot and restart
//---------------------------------

var dashboard_url;

function confirm_dashboard_function(url,msg)
{
    if (!window.confirm(msg))
        return;
    dashboard_url = url;
    dashboard_function(url);
    if (url == '/reboot' ||
        url == '/server/restart')
        $('.cover_screen').show();
}
function dashboard_function(what)
{
    $('#status2').html(what);
    httpRequest(what,onDashboardFunction,httpError,httpTimeout);
}
function onDashboardFunction()
{
    var seconds = 0;
    var text = this.responseText;
    text = text + "\n>>>" + dashboard_url + "done\n";
    if (dashboard_url == '/reboot')
        seconds = 60;
    if (dashboard_url == '/server/restart')
        seconds = 20;
    if (seconds)
    {
        text = text + "Reloading in " + seconds + " seconds\n";
        reloadIn(seconds);
    }
    $('#dashboard_content').html(text);
}



//---------------------------------
// update
//---------------------------------

var do_stash = false;

function confirm_function(fxn,msg)
{
    if (!window.confirm(msg))
        return;
    $('.cover_screen').show();
    fxn();
}
function updateSystem()
{
    var command = "/update_system";
    if (do_stash)
        command += "_stash";
    $('#status2').html(command);
    httpRequest(command,onUpdateResult,httpError,httpTimeout);
}
function onUpdateResult()
{
    var text = this.responseText;
    $('#dashboard_content').html(text);
    if (text.startsWith('GIT_NEEDS_STASH'))
    {
        do_stash = 1;
        $('#system_update_button').html('Update_Stash');
    }
    if (text.startsWith('GIT_UPDATE_DONE'))
    {
        text = text + "<br>\n>>> Update done - reloading page in 20 seconds <<<<br>";
        reloadIn(20);
    }
    else
    {
        $('.cover_screen').hide();
    }

    myAlert('Update',text);
    // $('#dashboard_content').html(text);
}


//---------------------------------
// utilities
//---------------------------------

var reload_seconds;

function reloadTimer()
{
    reload_seconds--;
    if (reload_seconds)
    {
        $('#status2').html("reload in " + reload_seconds);
        setTimeout(reloadTimer,1000);
    }
    else
    {
        $('#status2').html('reloading');
        location.reload();
    }
}


function reloadIn(seconds)
{
    reload_seconds = seconds;
    $('#status2').html("reload in " + seconds);
    setTimeout(reloadTimer,1000);
}



function myAlert(title,msg)
    // denormalized and slightly modified from iotCommon.js
{
    $('#alert_title').html(title);
    $('#alert_msg').html(msg);
    $('#alert_dlg').modal('show');
}

function httpRequest(url,success_method, error_method, timeout_method)
{
    var xhr = new XMLHttpRequest();
    xhr.timeout = 30000;
    xhr.onload = success_method;
    if (typeof(error_method) != 'undefined')
        xhr.onerror = error_method;
    if (typeof(timeout_method) != 'undefined')
        xhr.onerror = timeout_method;
    xhr.open("GET", url, true);
    xhr.the_url = url;
    xhr.send();
}
function httpError()
{
    $('.cover_screen').hide();
    alert("http error getting " + this.the_url);
}
function httpTimeout()
{
    $('.cover_screen').hide();
    alert("http timeout getting " + this.the_url);
}



//------------------------------------------------
// page initialization
//------------------------------------------------

function onStartPage()
{
    $('button[data-bs-toggle="tab"]').on('shown.bs.tab', onTab);
    if (!is_win)
        $('.linux_only').show();
    if (as_service)
        $('.service_only').show();
}


window.onload = onStartPage;
