//--------------------------------------------
// standard_system.js
//--------------------------------------------
// Standardized handling of HTTP::ServerBase 'system'
// commands:  reboot, restart_service, update_system(_stash).
// The responses for reboot and restart are single lines
// of text.  The responses for update_system are
// multi-lined html with page breaks that startWith()
// a Pub::ServiceUpdate GIT_XXX constant in text form.
//
// The function call is
//
//      onclick="javascript:standard_system_command('reboot')"
//
// in the calling html, which should be protected with styling
// (i.e. .linux_only) as appropriate
//
// All implementations require
//
//      <div class='.cover_screen'></div>
//          that is appropriately styled and a function
//          myAlert(title,msg) that accepts html in the message.
//      myAlert(title,msg) function
//          dialog box to show the results of a call
//          or an error
//
// init_standard_system_commands() optionally takes a hash
// containing the following values
//
//  show_command = selector for an html containing the command
//
//  update_button = selector for button to change from 'update' to
//      'update_stash' and back if need for stash is detected
//  countdown_timer = selector for html() of countdown timer
//
//  restart_time = number of seconds to allow a restart
//      before calling location.reload() on restart or
//      successfull update_system(_stash) returning
//      GIT_UPDATE_DONE. Default=10
//
//  reboot_time = number of seconds to allow for a reboot
//      before calling location.reload(). Default == 30


var needs_stash = false;
var system_command = '';
var reload_seconds;
var system_params = {};
var system_msgs = {
    'restart_service' : 'restart the service',
    'reboot' : 'reboot the computer',
    'update_system' : 'update the system source code',
    'update_system_stash' : 'stash changes and update the system source code', };


function init_standard_system_commands(in_params)
{
    system_params = in_params;
}


function standard_system_command(command)
{
    if (needs_stash && command == 'update_system')
        command = 'update_system_stash';
    var msg = system_msgs[command];
    if (!window.confirm(msg + "?"))
        return;
    if (system_params.show_command)
        $(system_params.show_command).html(command);
    $('.cover_screen').show();

    system_command = command;
    setTimeout(do_system_command,10);
}


function do_system_command()
{
    $.ajax({
        async: true,
        url: '/' + system_command,

        success: function (result)
        {
            if (system_command == 'reboot' ||
                system_command == 'restart_service' || (
                system_command.startsWith('update_system') &&
                result.startsWith('GIT_UPDATE_DONE')))
            {
                startReloadTimer();
                result += "<br>Restarting service in " + reload_seconds;
                myAlert(system_command,result);
            }
            else
            {
                myAlert(system_command,result);
                $('.cover_screen').hide();
                if (result.startsWith('GIT_NEEDS_STASH'))
                {
                    needs_stash = true;
                    if (system_params.update_button)
                        $(system_params.update_button).html('stash_update');
                }
                else if (result.startsWith('GIT_'))
                {
                    needs_stash = true;
                    if (system_params.update_button)
                        $(system_params.update_button).html('update');
                }
            }
        },

        error: function() {
            myAlert("ERROR!!!","There was an error calling " + system_command);
            $('.cover_screen').hide();
        },

        // timeout: 3000,
    });
}



function startReloadTimer()
{
    reload_seconds = params.restart_time ?
        params.restart_time : 10;
    if (system_command == 'reboot')
        reload_seconds = params.reboot_time ?
            params.reboot_time : 30;
    if (params.countdown_timer)
        $(parms.countdown_timer).html("reload in " + reload_seconds);
    setTimeout(reloadTimer,1000);
}


function reloadTimer()
{
    reload_seconds--;
    if (reload_seconds)
    {
        if (params.countdown_timer)
            $(parms.countdown_timer).html("reload in " + reload_seconds);
        setTimeout(reloadTimer,1000);
    }
    else
    {
        if (params.countdown_timer)
            $(parms.countdown_timer).html("reloading");
        location.reload();
    }
}
