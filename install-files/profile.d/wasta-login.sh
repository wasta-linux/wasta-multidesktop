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
#   2022-01-16 rik: initial jammy script
#
# ==============================================================================

DIR=/usr/share/wasta-multidesktop
LOGDIR=/var/log/wasta-multidesktop
LOGFILE="${LOGDIR}/wasta-login.txt"

# ENV variables set by DIR/scripts/set-session-env.sh:
#   - CURR_DM
#   - CURR_USER
#   - CURR_SESSION
#   - PREV_SESSION
# The script is sourced so that it can properly export the variables. Otherwise,
#   wasta-login.sh would have to not be run until set-session-env.sh is finished.
#   This also means that this script can't "exit", it must "return" instead.
source $DIR/scripts/set-session-env.sh


DEBUG_FILE="${LOGDIR}/wasta-login-debug"
# Get DEBUG status.
touch $DEBUG_FILE
DEBUG=$(cat $DEBUG_FILE)

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
    value=$(sudo --user=$CURR_USER --set-home dbus-launch gsettings get "$1" "$2")
    #value=$(/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings get "$1" "$2")
    #value=$(su $CURR_USER -c "dbus-launch gsettings get $1 $2")
    echo $value
}

gsettings_set() {
    # $1: key_path
    # $2: key
    # $3: value
    sudo --user=$CURR_USER --set-home dbus-launch gsettings set "$1" "$2" "$3" || true;
    #/usr/sbin/runuser -u $CURR_USER -- dbus-launch gsettings set "$1" "$2" "$3" || true;
    #su "$CURR_USER" -c "dbus-launch gsettings set $1 $2 $3" || true;
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

# Ensure LOGDIR.
mkdir -p "$LOGDIR"

# Get initial dconf/dbus pids.
PID_DCONF=$(pidof dconf-service)
PID_DBUS=$(pidof dbus-daemon)

# Log initial info.
log_msg
log_msg "$(date) starting wasta-login"
log_msg "display manager: $CURR_DM"
log_msg "current user: $CURR_USER"
log_msg "current session: $CURR_SESSION"
log_msg "PREV session for user: $PREV_SESSION"
if [ -x /usr/bin/nemo ]; then
    log_msg "TOP NEMO show desktop icons: $(gsettings_get org.nemo.desktop desktop-layout)"
fi

if [ -x /usr/bin/nautilus ]; then
    log_msg "NAUTILUS show desktop icons: $(gsettings_get org.gnome.desktop.background show-desktop-icons)"
    log_msg "NAUTILUS draw background: $(gsettings_get org.gnome.desktop.background draw-background)"
fi

# Check that CURR_USER is set.
if ! [ $CURR_USER ]; then
    log_msg "EXITING... no user found"
    exit 0
fi

# Check that CURR_SESSION is set.
if ! [ $CURR_SESSION ]; then
    log_msg "EXITING... no session found"
    exit 0
fi

# xfconfd: started but shouldn't be running (likely residual from previous
#   logged out xfce session)
if [ "$(pidof xfconfd)" ]; then
    log_msg "xfconfd is running and is being stopped: $(pidof xfconfd)"
    killall xfconfd | tee -a $LOGFILE
fi

# ------------------------------------------------------------------------------
# Store current backgrounds
# ------------------------------------------------------------------------------
if [ -x /usr/bin/cinnamon ]; then
    #cinnamon: "file://" precedes filename
    #2018-12-18 rik: will do urldecode but not currently necessary for cinnamon
    CINNAMON_BG_URL=$(gsettings_get org.cinnamon.desktop.background picture-uri)
    CINNAMON_BG=$(urldecode $CINNAMON_BG_URL)
fi

if [ -x /usr/bin/gnome-shell ]; then
    #gnome: "file://" precedes filename
    #2018-12-18 rik: urldecode necessary for gnome IF picture-uri set in gnome AND
    #   unicode characters present
    GNOME_BG_URL=$(gsettings_get org.gnome.desktop.background picture-uri)
    GNOME_BG=$(urldecode $GNOME_BG_URL)
fi

AS_FILE="/var/lib/AccountsService/users/$CURR_USER"
# Lightdm 1.26 uses a more standardized syntax for storing user backgrounds.
#   Since individual desktops would need to re-work how to set user backgrounds
#   for use by lightdm we are doing it manually here to ensure compatiblity
#   for all desktops
if ! [ $(grep "BackgroundFile=" $AS_FILE) ]; then
    # Error, so BackgroundFile needs to be added to AS_FILE
    echo  >> $AS_FILE
    echo "[org.freedesktop.DisplayManager.AccountsService]" >> $AS_FILE
    echo "BackgroundFile=''" >> $AS_FILE
fi
# Retrieve current AccountsService user background
AS_BG=$(sed -n "s@BackgroundFile=@@p" $AS_FILE)

if [ -x /usr/bin/xfce4-session ]; then
    XFCE_DEFAULT_SETTINGS="/etc/xdg/xdg-xfce/xfce4/"
    XFCE_SETTINGS="/home/$CURR_USER/.config/xfce4/"
    #if ! [ -e $XFCE_SETTINGS ];
    #then
    #    if [ $DEBUG ];
    #    then
    #        echo "Creating xfce4 settings folder for user" | tee -a $LOGFILE
    #    fi
    #    mkdir -p $XFCE_SETTINGS
    #    # cp -r $XFCE_DEFAULT_SETTINGS $XFCE_SETTINGS
    #fi

    XFCE_DEFAULT_DESKTOP="/etc/xdg/xdg-xfce/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
    XFCE_DESKTOP="/home/$CURR_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
    if ! [ -e $XFCE_DESKTOP ]; then
        log_msg "Creating xfce4-desktop.xml for user"
        mkdir -p $XFCE_SETTINGS/xfconf/xfce-perchannel-xml/
        cp $XFCE_DEFAULT_DESKTOP $XFCE_DESKTOP
    fi

    # since XFCE has different images per display and display names are
    # different, and also since xfce properly sets AccountService background
    # when setting a new background image, we will just use AS as xfce bg.
    XFCE_BG=$AS_BG

    #xfce: NO "file://" preceding filename
    #XFCE_BG=$(xmlstarlet sel -T -t -m \
    #    '//channel[@name="xfce4-desktop"]/property[@name="backdrop"]/property[@name="screen0"]/property[@name="monitorVirtual-1"]/property[@name="workspace0"]/property[@name="last-image"]/@value' \
    #    -v . -n $XFCE_DESKTOP)
    # not wanting to use xfconf-query because it starts xfconfd which then makes
    # it difficult to change user settings.
    #XFCE_BG=$(su "$CURR_USER" -c "dbus-launch xfconf-query -p /backdrop/screen0/monitor0/workspace0/last-image -c xfce4-desktop")
fi

# Log BG URL info.
if [ -x /usr/bin/cinnamon ]; then
    log_msg "cinnamon bg url encoded: $CINNAMON_BG_URL"
    log_msg "cinnamon bg url decoded: $CINNAMON_BG"
fi

if [ -x /usr/bin/xfce4-session ]; then
    log_msg "xfce bg: $XFCE_BG"
fi

if [ -x /usr/bin/gnome-shell ]; then
    log_msg "gnome bg url encoded: $GNOME_BG_URL"
    log_msg "gnome bg url decoded: $GNOME_BG"
fi

log_msg "as bg: $AS_BG"

# ------------------------------------------------------------------------------
# ALL Session Fixes
# ------------------------------------------------------------------------------

# SYSTEM level fixes:
# - we want app-adjustments to run every login to ensure that any updated
#   apps don't revert the customizations.
# - Triggering with 'at' so this login script is not delayed as
#   app-adjustments can run asynchronously.
echo "$DIR/scripts/app-adjustments.sh $*" | at now || true;

# USER level fixes:
# Ensure Nautilus not showing hidden files (power users may be annoyed)
if [ -x /usr/bin/nautilus ]; then
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

# --------------------------------------------------------------------------
# SYNC to PREV_SESSION (mainly for background picture)
# --------------------------------------------------------------------------
case "$PREV_SESSION" in

cinnamon|cinnamon2d)
    # apply Cinnamon settings to other DEs
    log_msg "Previous Session Cinnamon: Sync to other DEs"

    if [ -x /usr/bin/gnome-shell ]; then
        # sync Cinnamon background to GNOME background
        gsettings_set org.gnome.desktop.background picture-uri "$CINNAMON_BG"
    fi

    if [ -x /usr/bin/xfce4-session ]; then
        # first make sure xfconfd not running or else change won't load
        #killall xfconfd

        # sync Cinnamon background to XFCE background
        NEW_XFCE_BG=$(echo "$CINNAMON_BG" | sed "s@'file://@@" | sed "s@'\$@@")
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

    # sync Cinnamon background to AccountsService background
    NEW_AS_BG=$(echo "$CINNAMON_BG" | sed "s@file://@@")
    if [ "$AS_BG" != "$NEW_AS_BG" ]; then
        sed -i -e "s@\(BackgroundFile=\).*@\1$NEW_AS_BG@" $AS_FILE
    fi
;;

ubuntu|ubuntu-xorg|gnome|gnome-flashback-metacity|gnome-flashback-compiz|wasta-gnome)
    # apply GNOME settings to other DEs
    log_msg "Previous Session GNOME: Sync to other DEs"

    if [ -x /usr/bin/cinnamon ]; then
        # sync GNOME background to Cinnamon background
        gsettings_set org.cinnamon.desktop.background picture-uri "$GNOME_BG"
    fi

    if [ -x /usr/bin/xfce4-session ]; then
        # first make sure xfconfd not running or else change won't load
        #killall xfconfd

        # sync GNOME background to XFCE background
        NEW_XFCE_BG=$(echo "$GNOME_BG" | sed "s@'file://@@" | sed "s@'\$@@")
        log_msg "Attempting to set NEW_XFCE_BG: $NEW_XFCE_BG"
        #su "$CURR_USER" -c "dbus-launch xfce4-set-wallpaper $NEW_XFCE_BG" || true;

    # ?? why did I have this too? Doesn't sed below work?? maybe not....
    #        xmlstarlet ed --inplace -u \
    #        '//channel[@name="xfce4-desktop"]/property[@name="backdrop"]/property[@name="screen0"]/property[@name="monitorVirtual-1"]/property[@name="workspace0"]/property[@name="last-image"]/@value' \
    #        -v "$NEW_XFCE_BG" $XFCE_DESKTOP

        #set ALL properties with name "last-image" to use value of new background
        sed -i -e 's@\(name="last-image"\).*@\1 type="string" value="'"$NEW_XFCE_BG"'"/>@' \
            $XFCE_DESKTOP
    fi

    # sync GNOME background to AccountsService background
    NEW_AS_BG=$(echo "$GNOME_BG" | sed "s@file://@@")
    if [ "$AS_BG" != "$NEW_AS_BG" ]; then
        sed -i -e "s@\(BackgroundFile=\).*@\1$NEW_AS_BG@" $AS_FILE
    fi
;;

xfce|xubuntu)
    # apply XFCE settings to other DEs
    #XFCE_BG_URL=$(urlencode $XFCE_BG)
    XFCE_BG_NO_QUOTE=$(echo "$XFCE_BG" | sed "s@'@@g")

    #echo "xfce bg url: $XFCE_BG_URL" | tee -a $LOGFILE
    log_msg "Previous Session XFCE: Sync to other DEs"

    if [ -x /usr/bin/cinnamon ]; then
        # sync XFCE background to Cinnamon background
        gsettings_set org.cinnamon.desktop.background picture-uri "'file://$XFCE_BG_NO_QUOTE'"
    fi

    if [ -x /usr/bin/gnome-shell ]; then
        # sync XFCE background to GNOME background
        gsettings_set org.gnome.desktop.background picture-uri "'file://$XFCE_BG_NO_QUOTE'"
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
    # $PREV_SESSION unknown
    log_msg "Unsupported previous session: $PREV_SESSION"
    log_msg "Session NOT sync'd to other sessions"
;;

esac

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
        # allow nemo to draw the desktop
        gsettings_set org.nemo.desktop desktop-layout "'true::false'"

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
    if [ "$(pgrep blueman-applet)" ]; then
        killall blueman-applet | tee -a $LOGFILE
    fi

    # Prevent Gnome from drawing the desktop (for Xubuntu, Nautilus is not
    #   installed but these settings were still true, thus not allowing nemo
    #   to draw the desktop. So set to false all the time even if nautilus not
    #   installed.
    if [ -x /usr/bin/gnome-shell ]; then
        gsettings_set org.gnome.desktop.background show-desktop-icons false
        gsettings_set org.gnome.desktop.background draw-background false
    fi

    # ENABLE notify-osd
    if [ -e /usr/share/dbus-1/services/org.freedesktop.Notifications.service.disabled ]; then
        log_msg "Enabling notify-osd for cinnamon session"
        mv /usr/share/dbus-1/services/org.freedesktop.Notifications.service{.disabled,}
    fi

    # DISABLE gnome-screensaver.
    if [[ -e /usr/share/dbus-1/services/org.gnome.ScreenSaver.service ]]; then
        log_msg "Disabling gnome-screensaver for cinnamon session"
        mv /usr/share/dbus-1/services/org.gnome.ScreenSaver.service{,.disabled}
    fi

    # --------------------------------------------------------------------------
    # XFCE Settings
    # --------------------------------------------------------------------------
    # Thunar: hide (only installed for bulk-rename-tool)
    log_msg "Hiding XFCE apps from the desktop user"
    toggle_apps_visibility THUNAR_APPS 'hide'

    if [ -x /usr/bin/nemo ]; then
        log_msg "End cinnamon detected - NEMO show desktop icons: $(gsettings_get org.nemo.desktop desktop-layout)"
    fi

    if [ -x /usr/bin/gnome-shell ]; then
        log_msg "end cinnamon detected - NAUTILUS show desktop icons: $(gsettings_get org.gnome.desktop.background show-desktop-icons)"
        log_msg "end cinnamon detected - NAUTILUS draw background: $(gsettings_get org.gnome.desktop.background draw-background)"
    fi

    # Stop xfce4-notifyd.service.
    # su $CURR_USER -c "dbus-launch systemctl --user disable xfce4-notifyd.service"
    # 2021-04-09: This doesn't work (also tried sudo, runuser, in addidtion to su):
    # "Failed to disable unit xfce4-notifyd.service: Process org.freedesktop.systemd1 exited with status 1"
;;

ubuntu|ubuntu-xorg|ubuntu-wayland|gnome|gnome-flashback-metacity|gnome-flashback-compiz|wasta-gnome)
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

    # Reset ...app-folders folder-children if it's currently set as ['Utilities', 'YaST']
    key_path='org.gnome.desktop.app-folders'
    key='folder-children'
    curr_children=$(sudo --user=$CURR_USER gsettings get "$key_path" "$key")
    if [[ $curr_children = "['Utilities', 'YaST']" ]] || \
        [[ $curr_children = "['Utilities', 'Sundry', 'YaST']" ]]; then
        log_msg "Resetting gsettings $key_path $key"
        sudo --user=$CURR_USER --set-home dbus-launch gsettings reset "$key_path" "$key" 2>&1 >/dev/null | tee -a "$LOG"
    fi

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
        # Allow Nautilus to draw the desktop
        gsettings_set org.gnome.desktop.background show-desktop-icons true
        gsettings_set org.gnome.desktop.background draw-background true

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

        # set nemo to draw the desktop
        gsettings_set org.nemo.desktop desktop-layout "'true::false'"

        # ensure nemo can start if xfdesktop already running
        gsettings_set org.nemo.desktop ignored-desktop-handlers \"['conky', 'xfdesktop']\"

        # Ensure Nemo default folder handler
        sed -i \
            -e 's@\(inode/directory\)=.*@\1=nemo.desktop@' \
            -e 's@\(application/x-gnome-saved-search\)=.*@\1=nemo.desktop@' \
            /etc/gnome/defaults.list \
            /usr/share/applications/defaults.list || true;

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

    # Blueman-applet may be active: kill (will not error if not found)
    if [ "$(pgrep blueman-applet)" ]; then
        killall blueman-applet | tee -a $LOGFILE
    fi

    # Prevent Gnome from drawing the desktop (for Xubuntu, Nautilus is not
    #   installed but these settings were still true, thus not allowing nemo
    #   to draw the desktop. So set to false all the time even if nautilus not
    #   installed.
    if [ -x /usr/bin/gnome-shell ]; then
        gsettings_set org.gnome.desktop.background show-desktop-icons false
        gsettings_set org.gnome.desktop.background draw-background false
    fi

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

    # skypeforlinux: can't start minimized in xfce or will end up with an
    # empty window frame that can't be closed (without re-activating the
    # empty frame by clicking on the panel icon).  Note above skypeforlinux
    # autolaunch will always start it minimized (after 10 second delay)
#    if [ -e /home/$CURR_USER/.config/skypeforlinux/settings.json ];
#    then
#        # set launchMinimized = false
#        sed -i -e 's@"app.launchMinimized":true@"app.launchMinimized":false@' \
#            /home/$CURR_USER/.config/skypeforlinux/settings.json
#    fi

    # xfce clock applet loses it's config if opened and closed without first
    #    stopping the xfce4-panel.  So reset to defaults
    # https://askubuntu.com/questions/959339/xfce-panel-clock-disappears
#    XFCE_DEFAULT_PANEL="/etc/xdg/xdg-xfce/xfce4/panel/default.xml"
#    XFCE_PANEL="/home/$CURR_USER/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
#    if [ -e "$XFCE_PANEL" ];
#    then
        # using xmlstarlet since can't be sure of clock plugin #
#        DEFAULT_DIGITAL_FORMAT=$(xmlstarlet sel -T -t -m \
#            '//channel[@name="xfce4-panel"]/property[@name="plugins"]/property[@value="clock"]/property[@name="digital-format"]/@value' \
#           -v . -n $XFCE_DEFAULT_PANEL)
        #    DIGITAL_FORMAT=$(xmlstarlet sel -T -t -m \
        #        '//channel[@name="xfce4-panel"]/property[@name="plugins"]/property[@value="clock"]/property[@name="digital-format"]/@value' \
        #        -v . -n $XFCE_PANEL)
#        BLANK_DIGITAL_FORMAT=$(grep '"digital-format" type="string" value=""' $XFCE_PANEL)

 #       if [ "$BLANK_DIGITAL_FORMAT" ];
  #      then
#            if [ $DEBUG ];
#            then
#                echo "xfce4-panel clock digital-format removed: resetting" | tee -a $LOGFILE
#            fi
            # rik: below doesn't work since when $XFCE_PANEL put in ~/.config the NAMEs
            # are removed from the plugin properties: don't want to rely on plugin number so
            # instead will have to hack it with sed
            #        xmlstarlet ed --inplace -u \
            #            '//channel[@name="xfce4-panel"]/property[@name="plugins"]/property[@value="clock"]/property[@name="digital-format"]/@value' \
            #            -v "$DEFAULT_DIGITAL_FORMAT" $XFCE_PANEL
#            sed -i -e 's@\("digital-format" type="string" value=\)""@\1"'"$DEFAULT_DIGITAL_FORMAT"'"@' \
#                $XFCE_PANEL
#        fi

 #       DEFAULT_TOOLTIP_FORMAT=$(xmlstarlet sel -T -t -m \
  #          '//channel[@name="xfce4-panel"]/property[@name="plugins"]/property[@value="clock"]/property[@name="tooltip-format"]/@value' \
   #         -v . -n $XFCE_DEFAULT_PANEL)
    #    BLANK_TOOLTIP_FORMAT=$(grep '"tooltip-format" type="string" value=""' $XFCE_PANEL)

     #   if [ "$BLANK_TOOLTIP_FORMAT" ];
      #  then
       #     if [ $DEBUG ];
        #    then
         #       echo "xfce4-panel clock tooltip-format removed: resetting" | tee -a $LOGFILE
          #  fi
           # sed -i -e 's@\("tooltip-format" type="string" value=\)""@\1"'"$DEFAULT_TOOLTIP_FORMAT"'"@' $XFCE_PANEL
  #      fi
 #   fi
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
# SET PREV Session file for user
# ------------------------------------------------------------------------------
# > This is now done by "set-session-env.sh"
#echo $CURR_SESSION > $PREV_SESSION_FILE

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

log_msg "Final settings:"

if [ -x /usr/bin/cinnamon ]; then
    CINNAMON_BG_NEW=$(gsettings_get org.cinnamon.desktop.background picture-uri)
    log_msg "cinnamon bg NEW: $CINNAMON_BG_NEW"
fi

if [ -x /usr/bin/xfce4-session ]; then
    #XFCE_BG_NEW=$(su "$CURR_USER" -c "dbus-launch xfconf-query -p /backdrop/screen0/monitor0/workspace0/last-image -c xfce4-desktop" || true;)
    XFCE_BG_NEW=$(xmlstarlet sel -T -t -m \
        '//channel[@name="xfce4-desktop"]/property[@name="backdrop"]/property[@name="screen0"]/property[@name="monitorVirtual-1"]/property[@name="workspace0"]/property[@name="last-image"]/@value' \
        -v . -n $XFCE_DESKTOP)
    log_msg "xfce bg NEW: $XFCE_BG_NEW"
fi

if [ -x /usr/bin/gnome-shell ]; then
    GNOME_BG_NEW=$(gsettings_get org.gnome.desktop.background picture-uri)
    log_msg "gnome bg NEW: $GNOME_BG_NEW"
fi

AS_BG_NEW=$(sed -n "s@BackgroundFile=@@p" "$AS_FILE")
log_msg "as bg NEW: $AS_BG_NEW"

if [ -x /usr/bin/nemo ]; then
    log_msg "NEMO show desktop icons: $(gsettings_get org.nemo.desktop desktop-layout)"
fi

if [ -x /usr/bin/nautilus ]; then
    log_msg "NAUTILUS show desktop icons: $(gsettings_get org.gnome.desktop.background show-desktop-icons)"
    log_msg "NAUTILUS draw background: $(gsettings_get org.gnome.desktop.background draw-background)"
fi

# Kill dconf and dbus processes that were started during this script: often
#   they are not getting cleaned up leaving several "orphaned" processes. It
#   isn't terrible to keep them running but is more of a "housekeeping" item.

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

kill -9 $REMOVE_PID_DCONF
kill -9 $REMOVE_PID_DBUS

# Ensure files correctly owned by user
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.cache/
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.config/
chown -R $CURR_USER:$CURR_USER /home/$CURR_USER/.dbus/

log_msg "$(date) exiting wasta-login"

exit 0
