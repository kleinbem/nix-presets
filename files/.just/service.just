# `os service::*` — generic systemd service control.

start name:
    sudo systemctl start {{name}}

stop name:
    sudo systemctl stop {{name}}

restart name:
    sudo systemctl restart {{name}}

status name:
    systemctl status {{name}}
