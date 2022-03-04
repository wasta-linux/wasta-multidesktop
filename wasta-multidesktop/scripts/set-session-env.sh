#!/bin/bash

# ------------------------------------------------------------------------------
# For wasta-login.sh determine and export the following variables:
#   - display manager (CURR_DM)
#   - current session (CURR_SESSION)
#   - user's previous session (PREV_SESSION)
#   - user's previous session file (PREV_SESSION_FILE)
#
#   $1 passed parameter is UID of current user
#
# ------------------------------------------------------------------------------

# OR those 2 should be exported so available here??
#INPUT: $1 should be logdir
#INPUT: $2 should be debug value (or file?)

CURR_UID=$1
CURR_USER=$(id -un $CURR_UID)
if [[ "$CURR_USER" == "root" ]] || [[ "$CURR_USER" == "lightdm" ]] || [[ "$CURR_USER" == "gdm" ]]; then
    # do NOT process: curr user is root, lightdm, or gdm
    exit 0
fi

CURR_DM=''
CURR_SESSION=''
PREV_SESSION_FILE=''
PREV_SESSION=''

LOGDIR="/var/log/wasta-multidesktop"
mkdir -p "$LOGDIR"
LOG="${LOGDIR}/wasta-multidesktop.txt"
DEBUG_FILE="${LOGDIR}/debug"
# Get DEBUG status.
touch $DEBUG_FILE
DEBUG=$(cat $DEBUG_FILE)

SUPPORTED_DMS="gdm lightdm"

log_msg() {
    # Log "debug" messages to the logfile and "info" messages to systemd journal.
    title='WMD-env'
    type='info'
    if [[ $DEBUG == 'YES' ]]; then
        type='debug'
    fi
    msg="${title}: $@"
    if [[ $type == 'info' ]]; then
        #echo "$msg"
        true
    elif [[ $type == 'debug' ]]; then
        echo "$msg" | tee -a "$LOG"
    fi
}

script_exit() {
    # Export variables.
    export CURR_DM
    export CURR_SESSION
    export PREV_SESSION
    export PREV_SESSION_FILE

    # rik: since this runs on login AND logout do not want to update
    #    PREV_SESSION_FILE here, instead only do in wasta-logout.sh
    # Update PREV_SESSION_FILE.
    # echo $CURR_SESSION > $PREV_SESSION_FILE

    return $1
}

# ------------------------------------------------------------------------------
# Main processing
# ------------------------------------------------------------------------------

# Determine display manager.
#curr_dm=$(journalctl -b 0 | grep -i "New session .* of user lightdm\|New session .* of user gdm" | tail -n 1 | sed 's@^.*New session .* of user \(.*\)\.@\1@')
# Get rid of 2nd parenthesis.
#if [[ $(echo $SUPPORTED_DMS | grep -w $curr_dm) ]]; then
#    CURR_DM=$curr_dm
#else
    # Unsupported display manager!
#    log_msg "$(date)"
#    log_msg "Error: Display manager \"$curr_dm\" not supported."
    # Exit with code 0 so that login can continue.
#    script_exit 0
#fi

# 2022-01-17 rik: 22.04 gdm/lightdm logging reference:
# gdm creates session with c# for gdm and # only for REAL USER, e.g.:
#   systemd-logind[659]: New session c1 of user gdm.
#   systemd-logind[659]: New session 2 of user ubu.
# lightdm creates session with c# for both lightdm and REAL USER, e.g.:
#   systemd-logind[666]: New session c1 of user lightdm.
#   systemd-logind[666]: New session c2 of user ubu.
#CURR_USER=$(journalctl -b 0 | grep "New session .* of user " | tail -n 1 | sed 's@^.*New session .* of user \(.*\)\.@\1@')
log_msg "Setting CURR_USER:$CURR_USER"

CURR_SESSION_FILE="${LOGDIR}/$CURR_USER-curr-session"
touch $CURR_SESSION_FILE

# Get the user's previous session.
PREV_SESSION_FILE="${LOGDIR}/$CURR_USER-prev-session"
PREV_SESSION=$(cat $PREV_SESSION_FILE)

CURR_SESSION_ID=$(loginctl show-user $CURR_UID | grep Display= | sed s/Display=//)
if ! [ $CURR_SESSION_ID ]; then
    # NO display, so not graphical and don't continue
    exit 0
fi
CURR_SESSION=$(loginctl show-session $CURR_SESSION_ID | grep Desktop= | sed s/Desktop=//)
CURR_DM=$(loginctl show-session $CURR_SESSION_ID | grep Service= | sed s/Service=//)

# Get current user and session name (can't depend on full env at login).
if [[ $CURR_DM == 'gdm' ]]; then

    log_msg "GDM detected"
    # TODO: Need a different way to verify wayland session.
#    CURR_SESSION=$(journalctl -b 0 | grep "setting DESKTOP_SESSION=" | tail -n 1 | sed 's@^.*DESKTOP_SESSION=@@')
    # X: ubuntu-xorg
    # Way: ubuntu-wayland??

    # X:
    # grep "setting DESKTOP_SESSION=" | tail -n 1 | sed 's@^.*DESKTOP_SESSION=@@'
    # GdmSessionWorker: Set PAM environment variable: 'DESKTOP_SESSION=ubuntu'
    # GdmSessionWorker: start program: /usr/lib/gdm3/gdm-x-session --run-script \
    #   "env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --systemd --session=ubuntu"
    # Wayland:
    # GdmSessionWorker: Set PAM environment variable: 'DESKTOP_SESSION=ubuntu-wayland'
    # GdmSessionWorker: start program: /usr/lib/gdm3/gdm-wayland-session --run-script \
    #   "env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --systemd --session=ubuntu"
    #pat="s/.*DESKTOP_SESSION=(.*)'/\1/"
    #CURR_SESSION=$(echo $session_cmd | sed -r "$pat")

elif [[ $CURR_DM == 'lightdm' ]]; then
    # lightdm does NOT close user sessions on logout, meaning wasta-logout and
    # other systemd items expecting the session to close are not running
    # correctly. Setting "KillUserProcesses=yes" in logind config works around
    # this.
    sed -i -e "s@.*\(KillUserProcesses\).*@\1=yes@" /etc/systemd/logind.conf

    # since running at login and logout, need different way to detect
    # session since logs could have rotated resulting in undetected session
#    CURR_SESSION=$(grep -a "Greeter requests session" /var/log/lightdm/lightdm.log | \
#        tail -1 | sed 's@.*Greeter requests session \(.*\)@\1@')

#    if ! [[ "$CURR_SESSION" ]]; then
        # Get the user's saved current session (deleted by wasta-logout)
#        if [[ "$(cat $CURR_SESSION_FILE)" ]]; then
#            log_msg "CURR_SESSION not detected, loading from CURR_SESSION_FILE:$(cat $CURR_SESSION_FILE)"
#            CURR_SESSION=$(cat $CURR_SESSION_FILE)
#        fi
#    fi
fi

# SAVE user's current session
if [[ "$CURR_SESSION" ]]; then
    log_msg "Setting CURR_SESSION:$CURR_SESSION in CURR_SESSION_FILE:$CURR_SESSION_FILE"
    echo "$CURR_SESSION" > $PREV_SESSION_FILE
fi

script_exit 0
