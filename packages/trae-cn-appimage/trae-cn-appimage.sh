#!/bin/sh
# Launch the packaged AppImage. The AppImage keeps its own runtime and
# auto-update data inside the image, so nothing here touches the payload.
exec /opt/trae-cn-appimage/Trae-CN.AppImage "$@"
