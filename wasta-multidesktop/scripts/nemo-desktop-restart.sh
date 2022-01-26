#!/bin/bash

# in xfce, nemo-desktop ends up running, but not showing desktop icons. It is
# something to do with how it is started, possible conflict with
# xfdesktop, or other. At user level need to killall nemo-desktop and
# restart, but many contorted ways of doing it directly here haven't
# been successful, so making it a user level autostart.

sleep 2

killall nemo-desktop

nemo-desktop &

exit 0
