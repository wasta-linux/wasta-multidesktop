#!/bin/bash

# ==============================================================================
# Wasta-Linux Logout Script
#
#   This script is intended to run at logout to sync settings to other supported
#   Desktop Environments (such as syncing Background Files)
#
#   2022-02-01 rik: initial script
#
# ==============================================================================

CURR_UID=$1
CURR_USER=$(id -un $CURR_UID)
if [[ "$CURR_USER" == "root" ]] || [[ "$CURR_USER" == "lightdm" ]] || [[ "$CURR_USER" == "gdm" ]]; then
    # do NOT process: curr user is root, lightdm, or gdm
    exit 0
fi

DIR=/usr/share/wasta-multidesktop
LOGDIR=/var/log/wasta-multidesktop
mkdir -p ${LOGDIR}
LOGFILE="${LOGDIR}/wasta-multidesktop.txt"

DEBUG_FILE="${LOGDIR}/debug"
# Get DEBUG status.
touch $DEBUG_FILE
DEBUG=$(cat $DEBUG_FILE)

SUPPORTED_DMS="gdm lightdm"

# ------------------------------------------------------------------------------
# Define Functions
# ------------------------------------------------------------------------------

log_msg() {
    # Log "debug" messages to the logfile and "info" messages to systemd journal.
    title='WMD'
    type='info'
    if [[ $DEBUG == 'YES' ]]; then
        type='debug'
    fi
    msg="${title}: $@"
    if [[ $type == 'info' ]]; then
        #echo "$msg"                    # log to systemd journal
        true                            # no logging
    elif [[ $type == 'debug' ]]; then
        echo "$msg" | tee -a "$LOGFILE" # log both systemd journal and LOGFILE
    fi
}

# function: urldecode used to decode gnome picture-uri
# https://stackoverflow.com/questions/6250698/how-to-decode-url-encoded-string-in-shell
urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }

gsettings_get() {
    # $1: key_path
    # $2: key
    # NOTE: There's a security benefit of using sudo or runuser instead of su.
    #   su adds the user's entire environment, while sudo --set-home and runuser
    #   only set LOGNAME, USER, and HOME (sudo also sets MAIL) to match the user's.
    value=$(sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus gsettings get "$1" "$2")
    #value=$(/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings get "$1" "$2")
    #value=$(su $CURR_USER -c "dbus-launch gsettings get $1 $2")
    echo $value
}

gsettings_set() {
    # $1: key_path
    # $2: key
    # $3: value
    sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus gsettings set "$1" "$2" "$3" || true;
    #/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings set "$1" "$2" "$3" || true;
    #su "$CURR_USER" -c "dbus-launch gsettings set $1 $2 $3" || true;
}

# ------------------------------------------------------------------------------
# Main Processing
# ------------------------------------------------------------------------------

# Log initial info.
log_msg
log_msg "$(date) starting wasta-logout"

# ENV variables set by DIR/scripts/set-session-env.sh:
#   - CURR_DM
#   - CURR_USER
#   - CURR_SESSION
#   - PREV_SESSION
# The script is sourced so that it can properly export the variables. Otherwise,
#   wasta-login.sh would have to not be run until set-session-env.sh is finished.
#   This also means that this script can't "exit", it must "return" instead.
source $DIR/scripts/set-session-env.sh

#if [[ "$CURR_USER" == "gdm" ]] | [[ "$CURR_USER" == "lightdm" ]]; then
#    # exit, don't run on DM userids
#    logmsg "Exiting: don't run for CURR_USER:$CURR_USER"
#    exit 0
#fi

log_msg "user: $USER"
log_msg "curr user: $CURR_USER"
log_msg "curr usernum: $(id -u $CURR_USER)"
log_msg "current dm: $CURR_DM"
log_msg "current session: $CURR_SESSION"

AS_FILE="/var/lib/AccountsService/users/$CURR_USER"

# "-o" essential in case filename has a space in it.
if ! [ $(grep -o "BackgroundFile=" "$AS_FILE") ]; then
    # Error, so BackgroundFile needs to be added to AS_FILE
    echo  >> "$AS_FILE"
    echo "[org.freedesktop.DisplayManager.AccountsService]" >> "$AS_FILE"
    echo "BackgroundFile=''" >> "$AS_FILE"
fi
# Retrieve current AccountsService user background
AS_BG=$(sed -n "s@BackgroundFile=@@p" $AS_FILE)

case "$CURR_SESSION" in

cinnamon|cinnamon2d)
    #GET Cinnamon background
    #cinnamon: "file://" precedes filename
    #2018-12-18 rik: will do urldecode but not currently necessary for cinnamon
    BG_ENCODE=$(gsettings_get org.cinnamon.desktop.background picture-uri)
    BG=$(urldecode "$BG_ENCODE")
    log_msg "syncing Cinnamon bg to other locations: $BG"

    # sync Cinnamon background to Gnome-Shell background
    if [ -x /usr/bin/gnome-shell ]; then
        gsettings_set org.gnome.desktop.background picture-uri "$BG"
        gsettings_set org.gnome.desktop.screensaver picture-uri "$BG"
    fi

    # Cinnamon sets AccountsService background, no sync needed

    # sync Cinnamon background to XFCE background(s)
    if [ -x /usr/bin/xfce4-session ]; then
        # first make sure xfconfd not running or else change won't load
        #killall xfconfd

        NEW_XFCE_BG=$(echo "$BG" | sed "s@'file://@@" | sed "s@'\$@@")
        log_msg "Attempting to set NEW_XFCE_BG: $NEW_XFCE_BG"
        #su "$CURR_USER" -c "dbus-launch xfce4-set-wallpaper $NEW_XFCE_BG" || true;

    # ?? why did I have this too? Doesn't sed below work?? maybe not....
        #xmlstarlet ed --inplace -u \
        #    '//channel[@name="xfce4-desktop"]/property[@name="backdrop"]/property[@name="screen0"]/property[@name="monitorVirtual-1"]/property[@name="workspace0"]/property[@name="last-image"]/@value' \
        #    -v "$NEW_XFCE_BG" $XFCE_DESKTOP

        #set ALL properties with name "last-image" to use value of new background
        sed -i -e 's@\(name="last-image"\).*@\1 type="string" value="'"$NEW_XFCE_BG"'"/>@' \
            $XFCE_DESKTOP
    fi
;;

ubuntu|ubuntu-xorg|gnome|gnome-flashback-metacity|gnome-flashback-compiz|wasta-gnome)
    #GET GNOME background
    #gnome: "file://" precedes filename
    #2018-12-18 rik: urldecode necessary for gnome IF picture-uri set in gnome AND
    #   unicode characters present
    BG_ENCODE=$(gsettings_get org.gnome.desktop.background picture-uri)
    BG=$(urldecode "$BG_ENCODE")
    log_msg "syncing GNOME bg to other locations: $BG"

    # sync GNOME background to Cinnamon background
    if [ -x /usr/bin/cinnamon ]; then
        gsettings_set org.cinnamon.desktop.background picture-uri "$BG"
    fi

    # sync GNOME background to AccountsService background
    AS_BG=$(echo "$BG" | sed 's@file://@@')
    log_msg "Setting AccountsService BackgroundFile=$AS_BG"
    sed -i -e "s@\(BackgroundFile=\).*@\1$AS_BG@" $AS_FILE

    # sync GNOME background to XFCE background
    if [ -x /usr/bin/xfce4-session ]; then
        # first make sure xfconfd not running or else change won't load
        #killall xfconfd

        NEW_XFCE_BG=$(echo "$BG" | sed "s@'file://@@" | sed "s@'\$@@")
        log_msg "Attempting to set NEW_XFCE_BG: $NEW_XFCE_BG"
        #su "$CURR_USER" -c "dbus-launch xfce4-set-wallpaper $NEW_XFCE_BG" || true;

    # ?? why did I have this too? Doesn't sed below work?? maybe not....
        #xmlstarlet ed --inplace -u \
        #    '//channel[@name="xfce4-desktop"]/property[@name="backdrop"]/property[@name="screen0"]/property[@name="monitorVirtual-1"]/property[@name="workspace0"]/property[@name="last-image"]/@value' \
        #    -v "$NEW_XFCE_BG" $XFCE_DESKTOP

        #set ALL properties with name "last-image" to use value of new background
        sed -i -e 's@\(name="last-image"\).*@\1 type="string" value="'"$NEW_XFCE_BG"'"/>@' \
            $XFCE_DESKTOP
    fi
;;

xfce|xubuntu)
    # GET XFCE background
    # since XFCE has different images per display and display names are
    # different, and also since xfce properly sets AccountService background
    # when setting a new background image, we will just use AS as xfce bg.
    XFCE_BG=$AS_BG

    #XFCE_BG_URL=$(urlencode $XFCE_BG)
    XFCE_BG_NO_QUOTE=$(echo "$XFCE_BG" | sed "s@'@@g")

    #echo "xfce bg url: $XFCE_BG_URL" | tee -a $LOGFILE
    log_msg "Previous Session XFCE: Sync to other DEs"

    # sync XFCE background to Cinnamon background
    if [ -x /usr/bin/cinnamon ]; then
        gsettings_set org.cinnamon.desktop.background picture-uri "'file://$XFCE_BG_NO_QUOTE'"
    fi

    # sync XFCE background to GNOME background
    if [ -x /usr/bin/gnome-shell ]; then
        gsettings_set org.gnome.desktop.background picture-uri "'file://$XFCE_BG_NO_QUOTE'"
        gsettings_set org.gnome.desktop.screensaver picture-uri "'file://$XFCE_BG_NO_QUOTE'"
    fi

    # 20.04: I believe XFCE is properly setting AS so not repeating here
    #    # sync XFCE background to AccountsService background
    #    NEW_AS_BG="'$XFCE_BG'"
    #    if [ "$AS_BG" != "$NEW_AS_BG" ];
    #    then
    #        sed -i -e "s@\(BackgroundFile=\).*@\1$NEW_AS_BG@" $AS_FILE
    #    fi
;;

*)
    # SESSION not supported
    log_msg "Unsupported session: $XDG_SESSION_DESKTOP"
    log_msg "Session NOT sync'd to other sessions"
;;

esac

# ensure o+r permissions on AS_BG and o+rx on parent folders
AS_BG_NO_QUOTE=$(echo "$AS_BG" | sed "s@'@@g")
AS_BG_PATH=$(dirname "$AS_BG_NO_QUOTE")
while [[ "$AS_BG_PATH" != / ]]; do chmod o+rx "$AS_BG_PATH"; AS_BG_PATH=$(dirname "$AS_BG_PATH"); done;
chmod o+r "$AS_BG_NO_QUOTE"

# save $PREV_SESSION
log_msg "Setting CURR_SESSION:$CURR_SESSION to PREV_SESSION_FILE:$PREV_SESSION_FILE"
echo $CURR_SESSION > $PREV_SESSION_FILE

# blank $CURR_SESSION
CURR_SESSION_FILE="${LOGDIR}/$CURR_USER-curr-session"
log_msg "Removing entry from CURR_SESSION_FILE:$CURR_SESSION_FILE"
echo "" > $CURR_SESSION_FILE

# killall snapd processes (these often don't close on shutdown)
killall snapd 2>&1 || true;

log_msg "$(date) exiting wasta-logout"

exit 0

