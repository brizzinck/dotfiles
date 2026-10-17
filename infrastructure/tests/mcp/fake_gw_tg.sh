#!/usr/bin/env bash
echo "gateway $*" >>"$FAKE_DIR/argv.log"
SERVED="desktop-ro telegram${FAKE_GW_SEND:+ telegram-send}"
case $1 in
  headers) echo '{"Authorization":"Bearer test-gateway-token"}' ;;
  url) grep -qw -- "$2" <<<"$SERVED" || exit 1; echo "http://127.0.0.1:37411/$2/mcp" ;;
  servers) printf '%s\n' $SERVED ;;
  restart) echo restarted ;;
esac
