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



//--------------------------------------------
// file_server command()
//--------------------------------------------

function file_server_command(command)
{
    var msg = 'Are you sure you want to ' + command + " the File Server?";
    if (!window.confirm(msg))
        return;

    if (command == 'forward_start')
        fs_forwarded = true;
    if (command == 'forward_stop')
        fs_forwarded = false;
    showFSForwarded();

    var url = "/file_server/" + command;
    $('#status2').html(url);
    httpRequest(url,on_file_server_command,httpError,httpTimeout);
}
function on_file_server_command()
{
    var text = this.responseText;
    myAlert('fileServer',text);
}


//---------------------------------
// utilities
//---------------------------------

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

function showFSForwarded()
{
    if (fs_forwarded)
    {
        $('.fs_forwarded').show();
        $('.fs_not_forwarded').hide();
    }
    else
    {
        $('.fs_not_forwarded').show();
        $('.fs_forwarded').hide();
    }

}


function onStartPage()
{
    $('button[data-bs-toggle="tab"]').on('shown.bs.tab', onTab);
    if (!is_win)
        $('.linux_only').show();
    if (as_service)
        $('.service_only').show();
    if (is_forwarded)
        $('.is_not_forwarded').hide();
    else
        $('.is_forwarded').hide();

    showFSForwarded();

    init_standard_system_commands({
        show_command : '#status2',
        countdown_timer : '#status2',
        restart_time : 15,
        reboot_time : 45 });

}


window.onload = onStartPage;
