#!/bin/bash

# ------------------------------------------------------------------------------
# For wasta-login.sh determine and export the following variables:
#   - display manager (CURR_DM)
#   - current user (CURR_USER)
#   - current session (CURR_SESSION)
#   - user's previous session (PREV_SESSION)
# ------------------------------------------------------------------------------

CURR_DM=''
CURR_USER=''
CURR_SESSION=''
PREV_SESSION_FILE=''
PREV_SESSION=''

LOGDIR="/var/log/wasta-multidesktop"
LOG="${LOGDIR}/wasta-login.txt"
DEBUG_FILE="${LOGDIR}/wasta-login-debug"
# Get DEBUG status.
touch $DEBUG_FILE
DEBUG=$(cat $DEBUG_FILE)

SUPPORTED_DMS="gdm3 lightdm"

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
    export CURR_USER
    export CURR_SESSION
    export PREV_SESSION

    # Update PREV_SESSION_FILE.
    echo $CURR_SESSION > $PREV_SESSION_FILE

    return $1
}


# ------------------------------------------------------------------------------
# Main processing
# ------------------------------------------------------------------------------

mkdir -p '/var/log/wasta-multidesktop'
touch "$LOG"

# Determine display manager.
curr_dm=$(systemctl status display-manager.service | grep 'Main PID:' | awk -F'(' '{print $2}')
# Get rid of 2nd parenthesis.
curr_dm="${curr_dm::-1}"
if [[ $(echo $SUPPORTED_DMS | grep -w $curr_dm) ]]; then
    CURR_DM=$curr_dm
else
    # Unsupported display manager!
    log_msg "$(date)"
    log_msg "Error: Display manager \"$curr_dm\" not supported."
    # Exit with code 0 so that login can continue.
    script_exit 0
fi

2022-01-17 rik: below should work for any DM / DE in 22.04?
CURR_USER=$(journalctl | grep "New session [0-9]* of user " | tail -n 1 | sed 's@^.*New session .* of user \(.*\)\.@\1@')


# Get current user and session name (can't depend on full env at login).
if [[ $CURR_DM == 'gdm3' ]]; then

    # TODO: Need a different way to verify wayland session.
    CURR_SESSION=$(journalctl | grep "setting DESKTOP_SESSION=" | tail -n 1 | sed 's@^.*DESKTOP_SESSION=@@')
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
    CURR_SESSION=$(grep -a "Greeter requests session" /var/log/lightdm/lightdm.log | \
        tail -1 | sed 's@.*Greeter requests session \(.*\)@\1@')
fi

# Get the user's previous session.
PREV_SESSION_FILE="${LOGDIR}/$CURR_USER-prev-session"
PREV_SESSION=$(cat $PREV_SESSION_FILE)

script_exit 0
