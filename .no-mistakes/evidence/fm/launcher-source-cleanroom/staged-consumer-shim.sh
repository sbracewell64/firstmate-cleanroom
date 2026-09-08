#!/usr/bin/env bash
# GENERATED activation consumer for the clean-room captain launcher/console.
# DO NOT EDIT: render it from the source with bin/fm-render-launcher.sh.
# Source of truth: /tmp/tmp.1PLNQEsLz0/adopted-release/bin/enter-firstmate.sh
# Rendered: 20260908T211828Z
# This shim sets the operational home and execs the adopted release's launcher,
# which resolves every host path from $FM_HOME/config. The named Herdr session
# is still read from $FM_HOME/config/herdr-session by that source (unchanged).
export FM_HOME="/tmp/tmp.1PLNQEsLz0/fm-home"
exec "/tmp/tmp.1PLNQEsLz0/adopted-release/bin/enter-firstmate.sh" "$@"
