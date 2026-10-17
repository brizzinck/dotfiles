#!/usr/bin/env bash
echo "gateway $*" >>"$FAKE_DIR/argv.log"
case $1 in
  headers) echo '{"Authorization":"Bearer test-gateway-token"}' ;;
  url) echo "http://127.0.0.1:37411/$2/mcp" ;;
  servers) printf 'desktop-ro\ntelegram\n' ;;
  restart) echo restarted ;;
esac
