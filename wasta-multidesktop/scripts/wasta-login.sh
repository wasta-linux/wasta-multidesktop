#!/bin/bash

# ==============================================================================
# Wasta-Linux Login Script
#
#   This script is intended to run at login from /etc/profile.d. It makes DE
#       specific adjustments (for Cinnamon / XFCE / Gnome-Shell compatiblity)
#
#   NOTES:
#       - wmctrl needed to check if cinnamon running, because env variables
#           $GDMSESSION, $DESKTOP_SESSION not set when this script run by the
#           'session-setup-script' trigger in /etc/lightdm/lightdm.conf.d/* files
#       - logname is not set, but $CURR_USER does match current logged in user when
#           this script is executed by the 'session-setup-script' trigger in
#           /etc/lightdm/lightdm.conf.d/* files
#       - Appending '|| true;' to end of each call, because don't want to return
#           error if item not found (in case some items uninstalled).  the 'true'
#           will always return 0 from these commands.
#
# ==============================================================================

CURR_UID=$1
CURR_USER=$(id -un $CURR_UID)
if [[ "$CURR_USER" == "root" ]] || [[ "$CURR_USER" == "lightdm" ]] || [[ "$CURR_USER" == "gdm" ]] || [[ "$CURR_USER" == "" ]]; then
    # do NOT process: curr user is root, lightdm, gdm, or blank
    echo "Don't process based on CURR_USER:$CURR_USER"
    exit 0
fi

# login needs to wait for a few seconds to make sure env gets set up
sleep 10

DIR=/usr/share/wasta-multidesktop
LOGDIR=/var/log/wasta-multidesktop
mkdir -p ${LOGDIR}
LOGFILE="${LOGDIR}/wasta-multidesktop.txt"

DEBUG_FILE="${LOGDIR}/debug"
# Get DEBUG status.
touch $DEBUG_FILE
DEBUG=$(cat $DEBUG_FILE)

CURR_SESSION_FILE="${LOGDIR}/$CURR_USER-curr-session"

# The following apps lists are used to toggle apps' visibility off or on
#   according to the CURR_SESSION variable.
CINNAMON_APPS=(
    nemo.desktop
    cinnamon-online-accounts-panel.desktop
    cinnamon-settings-startup.desktop
    nemo-compare-preferences.desktop
)

GNOME_APPS=(
    alacarte.desktop
    blueman-manager.desktop
    gnome-online-accounts-panel.desktop
    gnome-session-properties.desktop
    gnome-tweak-tool.desktop
    org.gnome.Nautilus.desktop
    nautilus-compare-preferences.desktop
    software-properties-gnome.desktop
)

XFCE_APPS=(
    nemo.desktop
    nemo-compare-preferences.desktop
)

THUNAR_APPS=(
    thunar.desktop
    thunar-settings.desktop
)

# nullglob needed for detecting *racker* (Tracker services) below or else one
#   positive is returned even with no matches!
# from: https://stackoverflow.com/a/26255830
# nullglob is a Bash shell option which modifies [[glob]] expansion such
# that patterns that match no files expand to zero arguments, rather
# than to themselves.
shopt -s nullglob

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

    # this works without dbus-launch because user dbus created already - this is
    # preferred so that additional dbus-daemon processes aren't created
    value=$(sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus gsettings get "$1" "$2")
    #value=$(/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings get "$1" "$2")
    #value=$(sudo --user=$CURR_USER dbus-launch gsettings get $1 $2)
    echo $value
}

gsettings_set() {
    # $1: key_path
    # $2: key
    # $3: value
    sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus gsettings set "$1" "$2" "$3" || true;
    #/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings set "$1" "$2" "$3" || true;
    #sudo --user=$CURR_USER dbus-launch gsettings set "$1" "$2" "$3" || true;
}

toggle_apps_visibility() {
    local -n apps_array=$1
    visibility=$2

    # Set args.
    if [[ $visibility == 'show' ]]; then
        args=" --remove-key=NoDisplay "
    elif [[ $visibility == 'hide' ]]; then
        args=" --set-key=NoDisplay --set-value=true "
    fi

    # Apply to apps list.
    for app in "${apps_array[@]}"; do
        if [[ -e /usr/share/applications/$app ]]; then
            desktop-file-edit $args /usr/share/applications/$app || true;
        fi
    done
}

# ------------------------------------------------------------------------------
# Initial Setup
# ------------------------------------------------------------------------------

# Get initial dconf/dbus pids.
PID_DCONF=$(pidof dconf-service)
PID_DBUS=$(pidof dbus-daemon)

# Log initial info.
log_msg
log_msg "$(date) starting wasta-login for $CURR_USER"

# set log title
title='WMD-login'

log_msg "current uid: $CURR_UID"
log_msg "current user: $CURR_USER"

CURR_SESSION_ID=$(loginctl show-user $CURR_UID | grep Display= | sed s/Display=//)

log_msg "current session id: $CURR_SESSION_ID"

# check session data
if [[ "$CURR_SESSION_ID" ]]; then
    CURR_SESSION=$(loginctl show-session $CURR_SESSION_ID | grep Desktop= | sed s/Desktop=//)
    if [[ "$CURR_SESSION" ]]; then
        # graphical login - get DM and save current session
        CURR_DM=$(loginctl show-session $CURR_SESSION_ID | grep Service= | sed s/Service=//)
        log_msg "Setting CURR_SESSION:$CURR_SESSION in CURR_SESSION_FILE:$CURR_SESSION_FILE"
        echo "$CURR_SESSION" > $CURR_SESSION_FILE
    else
        # Not a graphical session since no Desktop entry in loginctl"
        log_msg "EXITING: not a GUI session for user $CURR_USER"
        exit 0
    fi
else
    # Shouldn't get here: no session id, so not graphical and don't continue
    log_msg "EXITING... no CURR_SESSION_ID"
    exit 0
fi

log_msg "current session: $CURR_SESSION"
log_msg "display manager: $CURR_DM"

# xfconfd: started but shouldn't be running (likely residual from previous
#   logged out xfce session)
if [ "$(pidof xfconfd)" ]; then
    log_msg "xfconfd is running and is being stopped: $(pidof xfconfd)"
    killall xfconfd | tee -a $LOGFILE
fi

# ------------------------------------------------------------------------------
# ALL Session Fixes
# ------------------------------------------------------------------------------

# USER level fixes:
# Ensure Nautilus not showing hidden files (power users may be annoyed)
if [ -x /usr/bin/nautilus ]; then
    # TODO 2022: below is legacy, desktop icons in extension now
    #gsettings_set org.gnome.desktop.background show-desktop-icons true
    #gsettings_set com.canonical.unity.desktop.background draw-background true
    gsettings_set org.gnome.nautilus.preferences show-hidden-files false
fi

if [ -x /usr/bin/nemo ]; then
    # Ensure Nemo not showing hidden files (power users may be annoyed)
    gsettings_set org.nemo.preferences show-hidden-files false

    # Ensure Nemo not showing "location entry" (text entry), but rather "breadcrumbs"
    gsettings_set org.nemo.preferences show-location-entry false

    # Ensure Nemo sorting by name
    gsettings_set org.nemo.preferences default-sort-order 'name'

    # Ensure Nemo sidebar showing
    gsettings_set org.nemo.window-state start-with-sidebar true

    # Ensure Nemo sidebar set to 'places'
    gsettings_set org.nemo.window-state side-pane-view 'places'
fi

if [ -x /usr/bin/nemo-desktop ]; then
    # Set Nemo to show desktop icons (won't conflict with Nautilus, GNOME)
    gsettings_set org.nemo.desktop desktop-layout "'true::false'"

    # Allow nemo-desktop to run even if xfdesktop is detected
    gsettings_set org.nemo.desktop ignored-desktop-handlers "['conky', 'xfdesktop']"
fi

# copy in zim prefs if don't already exist (these make trayicon work OOTB)
if ! [ -e /home/$CURR_USER/.config/zim/preferences.conf ]; then
    su "$CURR_USER" -c "cp -r $DIR/resources/skel/.config/zim \
        /home/$CURR_USER/.config/zim"
fi

# 20.04 not needed?????
# skypeforlinux: if autostart exists patch it to launch as indicator
#   (this fixes icon size in xfce and fixes menu options for all desktops)
#   (needs to be run every time because skypeforlinux re-writes this launcher
#    every time it is started)
#   https://askubuntu.com/questions/1033599/how-to-remove-skypes-double-icon-in-ubuntu-18-04-mate-tray
#if [ -e /home/$CURR_USER/.config/autostart/skypeforlinux.desktop ];
#then
    # appindicator compatibility + manual minimize (xfce can't mimimize as
    # the "insides" of the window are minimized and don't exist but the
    # empty window frame remains behind: so close Skype window after 10 seconds)
#    desktop-file-edit --set-key=Exec --set-value='sh -c "env XDG_CURRENT_DESKTOP=Unity /usr/bin/skypeforlinux %U && sleep 10 && wmctrl -c Skype"' \
#        /home/$CURR_USER/.config/autostart/skypeforlinux.desktop
#fi

# ------------------------------------------------------------------------------
# Processing based on current session
# ------------------------------------------------------------------------------
case "$CURR_SESSION" in
cinnamon|cinnamon2d)
    # ==========================================================================
    # ACTIVE SESSION: CINNAMON
    # ==========================================================================
    log_msg "processing based on CINNAMON session"

    # --------------------------------------------------------------------------
    # CINNAMON Settings
    # --------------------------------------------------------------------------
    # SHOW CINNAMON items
    log_msg "Ensuring that Cinnamon apps are visible to the desktop user"
    toggle_apps_visibility CINNAMON_APPS 'show'

    if [ -x /usr/bin/nemo ]; then
        # Ensure Nemo default folder handler
        sed -i \
            -e 's@\(inode/directory\)=.*@\1=nemo.desktop@' \
            -e 's@\(application/x-gnome-saved-search\)=.*@\1=nemo.desktop@' \
            /etc/gnome/defaults.list \
            /usr/share/applications/defaults.list || true;
    fi

    # ENABLE cinnamon-screensaver
    if [ -e /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service.disabled ]; then
        log_msg "Enabling cinnamon-screensaver for cinnamon session"
        mv /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service{.disabled,}
    fi

    # --------------------------------------------------------------------------
    # Ubuntu/GNOME Settings
    # --------------------------------------------------------------------------
    # HIDE Ubuntu/GNOME items
    log_msg "Hiding GNOME apps from the desktop user"
    toggle_apps_visibility GNOME_APPS 'hide'

    # Blueman-applet may be active: kill (will not error if not found)

# rumor is that Mint 21 will h ave blueman as default not blueberry
    #if [ "$(pgrep blueman-applet)" ]; then
    #    killall blueman-applet | tee -a $LOGFILE
    #fi

    # ENABLE notify-osd
    if [ -e /usr/share/dbus-1/services/org.freedesktop.Notifications.service.disabled ]; then
        log_msg "Enabling notify-osd for cinnamon session"
        mv /usr/share/dbus-1/services/org.freedesktop.Notifications.service{.disabled,}
    fi

    # DISABLE gnome-screensaver
    if [[ -e /usr/share/dbus-1/services/org.gnome.ScreenSaver.service ]]; then
        log_msg "Disabling gnome-screensaver for cinnamon session"
        mv /usr/share/dbus-1/services/org.gnome.ScreenSaver.service{,.disabled}
    fi

    # disable and stop tracker services
    if [[ -x /usr/bin/tracker ]] || [[ -x /usr/bin/tracker3 ]]; then
        log_msg "Disabling and stopping tracker services"
        # stop and disable tracker services
        for SERVICE in /usr/share/dbus-1/services/*racker*.service; do
            log_msg "Disabling tracker service: $SERVICE"
            #sudo --user=$CURR_USER --set-home dbus-launch systemctl --user stop $SERVICE
            #sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus systemctl --user mask $SERVICE 2>&1 | tee -a $LOGFILE
            mv $SERVICE{,.disabled}
        done
        # kill any currently running tracker services
        killall -r tracker-.* || true;
    fi

    # --------------------------------------------------------------------------
    # XFCE Settings
    # --------------------------------------------------------------------------
    # Thunar: hide (only installed for bulk-rename-tool)
    log_msg "Hiding XFCE apps from the desktop user"
    toggle_apps_visibility THUNAR_APPS 'hide'

    # Stop xfce4-notifyd.service.
    # su $CURR_USER -c "dbus-launch systemctl --user disable xfce4-notifyd.service"
    # 2021-04-09: This doesn't work (also tried sudo, runuser, in addidtion to su):
    # "Failed to disable unit xfce4-notifyd.service: Process org.freedesktop.systemd1 exited with status 1"
;;

ubuntu|ubuntu-xorg|ubuntu-wayland|gnome|gnome-flashback-metacity|gnome-flashback-compiz|wasta-gnome|wasta-gnome-xorg|wasta-gnome-wayland)
    # ==========================================================================
    # ACTIVE SESSION: UBUNTU / GNOME
    # ==========================================================================
    log_msg "Processing based on UBUNTU / GNOME session"

    # --------------------------------------------------------------------------
    # CINNAMON Settings
    # --------------------------------------------------------------------------
    # Hide Cinnamon apps from GNOME user.
    log_msg "Hiding Cinnamon apps from the desktop user"
    toggle_apps_visibility CINNAMON_APPS 'hide'

    if [ -x /usr/bin/nemo ]; then
        # Nemo may be active: kill (will not error if not found)
        if [ "$(pidof nemo-desktop)" ]; then
            log_msg "nemo-desktop running (MID) and needs killed: $(pidof nemo-desktop)"
            killall nemo-desktop | tee -a $LOGFILE
        fi
    fi

    # DISABLE cinnamon-screensaver
    if [ -e /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service ]; then
        log_msg "Disabling cinnamon-screensaver for gnome/ubuntu session"
        mv /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service{,.disabled}
    fi

    # --------------------------------------------------------------------------
    # Ubuntu/GNOME Settings
    # --------------------------------------------------------------------------

    # 22.04: Gnome allows "drag drop on the fly" folder creation now, so don't
    #   force on users, they can manage as they see fit.
    # Reset ...app-folders folder-children if it's currently set as ['Utilities', 'YaST']
    #key_path='org.gnome.desktop.app-folders'
    #key='folder-children'
    #curr_children=$(sudo --user=$CURR_USER gsettings get "$key_path" "$key")
    #if [[ $curr_children = "['Utilities', 'YaST']" ]] || \
    #    [[ $curr_children = "['Utilities', 'Sundry', 'YaST']" ]]; then
    #    log_msg "Resetting gsettings $key_path $key"
    #    sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus gsettings reset "$key_path" "$key" 2>&1 >/dev/null | tee -a $LOGFILE
    #fi

    # Make adjustments if using lightdm.
    if [[ $CURR_DM == 'lightdm' ]]; then
        if [[ -e /usr/share/dbus-1/services/org.gnome.ScreenSaver.service.disabled ]]; then
            log_msg "Enabling gnome-screensaver for lightdm."
            mv /usr/share/dbus-1/services/org.gnome.ScreenSaver.service{.disabled,}
        else
            # gnome-screensaver not previously disabled at login.
            log_msg "gnome-screensaver already enabled prior to lightdm login."
        fi
    fi

    # SHOW GNOME Items
    log_msg "Setting GNOME apps as visible to the desktop user"
    toggle_apps_visibility GNOME_APPS 'show'

    if [ -e /usr/share/applications/org.gnome.Nautilus.desktop ]; then
        # Ensure Nautilus default folder handler
        sed -i \
            -e 's@\(inode/directory\)=.*@\1=org.gnome.Nautilus.desktop@' \
            -e 's@\(application/x-gnome-saved-search\)=.*@\1=org.gnome.Nautilus.desktop@' \
            /etc/gnome/defaults.list \
            /usr/share/applications/defaults.list || true;
    fi

    # ENABLE notify-osd
    if [ -e /usr/share/dbus-1/services/org.freedesktop.Notifications.service.disabled ]; then
        log_msg "Enabling notify-osd for gnome/ubuntu session"
        mv /usr/share/dbus-1/services/org.freedesktop.Notifications.service{.disabled,}
    fi

    # enable and start tracker services
    if [ -x /usr/bin/tracker ] | [ -x /usr/bin/tracker3 ]; then
        # enable tracker services
        log_msg "Enabling and starting tracker services"
        for SERVICE in /usr/share/dbus-1/services/*racker*.service.disabled; do
            log_msg "Enabling tracker service: $SERVICE"
            #sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus systemctl --user unmask $SERVICE 2>&1 | tee -a $LOGFILE
            #sudo --user=$CURR_USER --set-home dbus-launch systemctl --user enable $SERVICE
            #sudo --user=$CURR_USER --set-home dbus-launch systemctl --user start $SERVICE
            #mv $SERVICE{.disabled,}
            rename 's/.disabled$//;' $SERVICE
        done
    fi

    # --------------------------------------------------------------------------
    # XFCE Settings
    # --------------------------------------------------------------------------
    log_msg "Hiding Thunar apps from the desktop user"
    toggle_apps_visibility THUNAR_APPS 'hide'
;;

xfce|xubuntu)
    # ==========================================================================
    # ACTIVE SESSION: XFCE
    # ==========================================================================
    log_msg "Processing based on XFCE session"

    # --------------------------------------------------------------------------
    # CINNAMON Settings
    # --------------------------------------------------------------------------
    if [ -x /usr/bin/nemo ]; then
        # SHOW XFCE Items
        #   nemo default file manager for wasta-xfce
        log_msg "Setting XFCE apps as visible to the desktop user"
        toggle_apps_visibility XFCE_APPS 'show'

        # Ensure Nemo default folder handler
        sed -i \
            -e 's@\(inode/directory\)=.*@\1=nemo.desktop@' \
            -e 's@\(application/x-gnome-saved-search\)=.*@\1=nemo.desktop@' \
            /etc/gnome/defaults.list \
            /usr/share/applications/defaults.list || true;

        # TODO-2022: check for 22.04
        # nemo-desktop ends up running, but not showing desktop icons. It is
        # something to do with how it is started, possible conflict with
        # xfdesktop, or other. At user level need to killall nemo-desktop and
        # restart, but many contorted ways of doing it directly here haven't
        # been successful, so making it a user level autostart.

        NEMO_RESTART="/home/$CURR_USER/.config/autostart/nemo-desktop-restart.desktop"
        if ! [ -e "$NEMO_RESTART" ]; then
            # create autostart
            log_msg "Linking nemo-desktop-restart for xfce compatibility"
            su $CURR_USER -c "mkdir -p /home/$CURR_USER/.config/autostart"
            su $CURR_USER -c "ln -s $DIR/resources/nemo-desktop-restart.desktop $NEMO_RESTART"
        fi
    fi

    # DISABLE cinnamon-screensaver
    if [ -e /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service ]; then
        log_msg "Disabling cinnamon-screensaver for xfce session"
        mv /usr/share/dbus-1/services/org.cinnamon.ScreenSaver.service{,.disabled}
    fi

    # --------------------------------------------------------------------------
    # Ubuntu/GNOME Settings
    # --------------------------------------------------------------------------

    # HIDE Ubuntu/GNOME items
    log_msg "Hiding GNOME apps from the desktop user"
    toggle_apps_visibility GNOME_APPS 'hide'

    # TODO-2022: check status of this
    # Blueman-applet may be active: kill (will not error if not found)
    #if [ "$(pgrep blueman-applet)" ]; then
    #    killall blueman-applet | tee -a $LOGFILE
    #fi

    # TODO-2022: check status of this - maybe do need to toggle on and off....
    # Prevent Gnome from drawing the desktop (for Xubuntu, Nautilus is not
    #   installed but these settings were still true, thus not allowing nemo
    #   to draw the desktop. So set to false all the time even if nautilus not
    #   installed.
    #if [ -x /usr/bin/gnome-shell ]; then
        #gsettings_set org.gnome.desktop.background show-desktop-icons false
        #gsettings_set com.canonical.unity.desktop.background draw-background false
    #fi

    # DISABLE notify-osd (xfce uses xfce4-notifyd)
    if [ -e /usr/share/dbus-1/services/org.freedesktop.Notifications.service ]; then
        log_msg "Disabling notify-osd for xfce session"
        mv /usr/share/dbus-1/services/org.freedesktop.Notifications.service{,.disabled}
    fi

    # DISABLE gnome-screensaver.
    if [[ -e /usr/share/dbus-1/services/org.gnome.ScreenSaver.service ]]; then
        log_msg "Disabling gnome-screensaver for cinnamon session"
        mv /usr/share/dbus-1/services/org.gnome.ScreenSaver.service{,.disabled}
    fi

    # disable and stop tracker services
    if [[ -x /usr/bin/tracker ]] || [[ -x /usr/bin/tracker3 ]]; then
        log_msg "Disabling and stopping tracker services"
        # stop and disable tracker services
        for SERVICE in /usr/share/dbus-1/services/*racker*.service; do
            log_msg "Disabling tracker service: $SERVICE"
            #sudo --user=$CURR_USER --set-home dbus-launch systemctl --user stop $SERVICE
            #sudo --user=$CURR_USER DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$CURR_UID/bus systemctl --user mask $SERVICE 2>&1 | tee -a $LOGFILE
            mv $SERVICE{,.disabled}
        done
        # kill any currently running tracker services
        killall -r tracker-.* || true;
    fi

    # --------------------------------------------------------------------------
    # XFCE Settings
    # --------------------------------------------------------------------------

    log_msg "Hiding Thunar apps from the desktop user"
    toggle_apps_visibility THUNAR_APPS 'hide'

    # xfdesktop used for background but does NOT draw desktop icons
    # (app-adjustments adds XFCE to OnlyShowIn to trigger nemo-desktop)
    # NOTE: XFCE_DESKTOP file created above in background sync

    # first: determine if element exists
    # style: 0 - None
    #        2 - File/launcher icons
    DESKTOP_STYLE=""
    DESKTOP_STYLE=$(xmlstarlet sel -T -t -m \
        '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]/property[@name="style"]/@value' \
        -v . -n $XFCE_DESKTOP)

    # second: create element else update element
    if [ "$DESKTOP_STYLE" == "" ]; then
        # create key
        log_msg "Creating xfce4-desktop/desktop-icons/style element"
        xmlstarlet ed --inplace \
            -s '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]' \
                -t elem -n "property" -v "" \
            -i '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]/property[last()]' \
                -t attr -n "name" -v "style" \
            -i '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]/property[@name="style"]' \
                -t attr -n "type" -v "int" \
            -i '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]/property[@name="style"]' \
                -t attr -n "value" -v "0" \
            $XFCE_DESKTOP
    else
        # update key
        xmlstarlet ed --inplace \
            -u '//channel[@name="xfce4-desktop"]/property[@name="desktop-icons"]/property[@name="style"]/@value' \
            -v "0" $XFCE_DESKTOP
    fi
;;

*)
    # ==========================================================================
    # ACTIVE SESSION: not supported yet
    # ==========================================================================
    log_msg "Desktop session not supported: $CURR_SESSION"

    # Thunar: show (even though only installed for bulk-rename-tool)
    log_msg "Setting Thunar apps as visible to the desktop user"
    toggle_apps_visibility THUNAR_APPS 'show'
;;

esac

# ------------------------------------------------------------------------------
# FINISHED
# ------------------------------------------------------------------------------

if [ -x /usr/bin/nemo ]; then
    if [ "$(pidof nemo-desktop)" ]; then
        log_msg "END: nemo-desktop IS running!"
    else
        log_msg "END: nemo-desktop NOT running!"
    fi
fi

# Kill dconf and dbus processes that were started during this script: often
#   they are not getting cleaned up leaving several "orphaned" processes. It
#   isn't terrible to keep them running but is more of a "housekeeping" item.

END_PID_DCONF=$(pidof dconf-service)
REMOVE_PID_DCONF=$END_PID_DCONF
# thanks to nate marti for cleaning up this detection of which PIDs need killing
for p in $PID_DCONF; do
    REMOVE_PID_DCONF=$(echo $REMOVE_PID_DCONF | sed "s/$p//")
done

END_PID_DBUS=$(pidof dbus-daemon)
REMOVE_PID_DBUS=$END_PID_DBUS
# thanks to nate marti for cleaning up this detection of which PIDs need killing
for p in $PID_DBUS; do
    REMOVE_PID_DBUS=$(echo $REMOVE_PID_DBUS | sed "s/$p//")
done

log_msg "dconf pid start: $PID_DCONF"
log_msg "dconf pid end: $END_PID_DCONF"
log_msg "dconf pid to kill: $REMOVE_PID_DCONF"
log_msg "dbus pid start: $PID_DBUS"
log_msg "dbus pid end: $END_PID_DBUS"
log_msg "dbus pid to kill: $REMOVE_PID_DBUS"

if [ "$REMOVE_PID_DCONF" ]; then
    kill -9 $REMOVE_PID_DCONF
fi

if [ "$REMOVE_PID_DBUS" ]; then
    kill -9 $REMOVE_PID_DBUS
fi

# Ensure files correctly owned by user
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.cache/
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.config/
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.dbus/

log_msg "$(date) exiting wasta-login for $CURR_USER"

exit 0
