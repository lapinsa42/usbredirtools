#!/bin/bash

function qm_monitor {
    local VM="$1"
    local COMMAND="$2"

    case $BACKEND in
        'libvirt' )
            virsh qemu-monitor-command --hmp "$VM" "$COMMAND"
        ;;
        'proxmox' )
            expect -c 'log_user 0; spawn /usr/sbin/qm monitor '"$VM"'; send "'"$COMMAND"'\r"; expect "qm>"; log_user 1; expect "qm>"; log_user 0; send "quit\r"; expect eof;' | head -n -1
        ;;
    esac
}

function log_info {
    echo "info: $1"
    logger "info: $1"
}

function log_debug {
    if [ "$DEBUG" == true ]; then
        echo "debug: $1"
        logger "debug: $1"
    fi
}


function check_and_reconnect {
    chardevs=($(ps aux | grep -oP '(?<=\-chardev )[^ ]*host=([0-9]+\.?){4}[^ ]*'))

    for i in ${chardevs[@]}; do
        CHARDEV="$i"
        CHARDEV_ID=$(echo "$CHARDEV" | grep -oP '(?<=id=)[^,]*')
        CHARDEV_HOST=$(echo "$CHARDEV" | grep -oP '(?<=host=)[^,]*')
        CHARDEV_PORT=$(echo "$CHARDEV" | grep -oP '(?<=port=)[0-9]*')

        case $BACKEND in
            'libvirt' ) VM=$(ps aux | grep "$CHARDEV" | grep -oP '(?<=\-name )[^ ]*') ;;
            'proxmox' ) VM=$(ps aux | grep "$CHARDEV" | grep -oP '(?<=\-id )[0-9]*') ;;
        esac

        CHARDEV_MONIT="$(qm_monitor "$VM" 'info chardev' | grep "${CHARDEV_HOST}:${CHARDEV_PORT}")"

        # Check status
        if [ -z "$CHARDEV_MONIT" ]; then
            CHARDEV_STATUS='not exist'
        elif $(echo "$CHARDEV_MONIT" | grep -q 'disconnected'); then
            CHARDEV_STATUS='disconnected'
        else
            CHARDEV_STATUS='connected'
        fi

        if [ "$CHARDEV_STATUS" != "connected" ] && $(qm_monitor "$VM" 'info status' | grep -q 'running' 2> /dev/null); then

            log_info "Chardev for ${CHARDEV_HOST}:${CHARDEV_PORT} is $CHARDEV_STATUS on ${VM}. Reconnecting..."

            DEVICE=$(ps aux | grep "$CHARDEV" | grep -oP '(?<=\-device )[^ ]*'$CHARDEV_ID'[^ ]*')
            DEVICE_ID=$(echo "$DEVICE" | grep -oP '(?<=id=)[^,]*')

            case $BACKEND in
                'libvirt' )
                    if [ "$CHARDEV_STATUS" == "disconnected" ]; then
                        # Remove usb device
                        DEVICE_ID="$(echo $CHARDEV_MONIT | grep -Po '(?<=char)redir[0-9]+')"
                        QM_DEVICE_DEL_OUTPUT="$(qm_monitor "$VM" "device_del $DEVICE_ID" 2>&1)"
                        log_debug "device_del $DEVICE_ID: ${QM_DEVICE_DEL_OUTPUT:-OK}"
                    fi

                    # Add usb device
                    DEVICE_FILE="$(mktemp)"
                    echo "<redirdev bus='usb' type='tcp'><source mode='connect' host='${CHARDEV_HOST}' service='${CHARDEV_PORT}'/></redirdev>" >> "$DEVICE_FILE"
                    VIRSH_ATTACH_DEVICE_OUTPUT="$(virsh attach-device "$VM" "$DEVICE_FILE" 2>&1)"

                    # If chardev does not exist error
                    if $(echo "$VIRSH_ATTACH_DEVICE_OUTPUT" | grep -q "Property 'usb-redir.chardev' can't find value"); then
                        CHARDEV_ID="$(echo $VIRSH_ATTACH_DEVICE_OUTPUT | grep -Po "(?<=Property 'usb-redir.chardev' can't find value ')[^']*")"
                        CHARDEV="socket,id=${CHARDEV_ID},host=${CHARDEV_HOST},port=${CHARDEV_PORT}"
                        # Create chardev and save output
                        QM_CHARDEV_ADD_OUTPUT="$(qm_monitor "$VM" "chardev-add $CHARDEV" 2>&1)"
                        log_debug "chardev-add $CHARDEV: ${QM_CHARDEV_ADD_OUTPUT:-OK}"
                        VIRSH_ATTACH_DEVICE_OUTPUT="$(virsh attach-device "$VM" "$DEVICE_FILE" 2>&1)"
                    fi
                    log_debug "attach-device: ${VIRSH_ATTACH_DEVICE_OUTPUT:-OK}"
                    rm -f $DEVICE_FILE

	        ;;
                'proxmox' )
                    if [ "$CHARDEV_STATUS" == "disconnected" ]; then
                        # Remove usb device
                        QM_DEVICE_DEL_OUTPUT="$(qm_monitor "$VM" "device_del $DEVICE_ID" 2>&1)"
                        log_debug "device_del $DEVICE_ID: ${QM_DEVICE_DEL_OUTPUT:-OK}"
                    fi

                    # Create chardev and save output
                    QM_CHARDEV_ADD_OUTPUT="$(qm_monitor "$VM" "chardev-add $CHARDEV" 2>&1)"

                    # Check if chardev-add operation return duplucate error
                    if $(echo "$QM_CHARDEV_ADD_OUTPUT" | grep -q "Duplicate ID"); then
                        RANDOM_NUM=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c8)
                        CHARDEV_ID_OLD="${CHARDEV_ID}"
                        CHARDEV_ID="$(echo ${CHARDEV_ID} | sed 's/_[A-Za-z0-9]\{8\}_$//')_${RANDOM_NUM}_"
                        CHARDEV=$(echo "$CHARDEV" | sed "s|id=${CHARDEV_ID_OLD}|id=${CHARDEV_ID}|")
                        DEVICE=$(echo "$DEVICE" | sed -r -e "s|chardev=${CHARDEV_ID_OLD}|chardev=${CHARDEV_ID}|g")

                        # Create chardev and save output
                        QM_CHARDEV_ADD_OUTPUT="$(qm_monitor "$VM" "chardev-add $CHARDEV" 2>&1)"
                    fi
                    log_debug "chardev-add $CHARDEV: ${QM_CHARDEV_ADD_OUTPUT:-OK}"

                    # Remove charde if chardev-add operation return error
                    if $(echo "$QM_CHARDEV_ADD_OUTPUT" | grep -q 'Failed to connect socket\|Duplicate ID'); then
                        QM_CHARDEV_REMOVE_OUTPUT="$(qm_monitor "$VM" "chardev-remove $CHARDEV_ID" 2>&1)"
                        log_debug "chardev-remove $CHARDEV: ${QM_CHARDEV_REMOVE_OUTPUT:-OK}"
                    fi

                    # Add usb device
                    QM_DEVICE_ADD_OUTPUT="$(qm_monitor "$VM" "device_add $DEVICE" 2>&1)"
                    log_debug "device_add $DEVICE: ${QM_DEVICE_ADD_OUTPUT:-OK}"
	        ;;
            esac
        fi 
    done
}

function loop {
    check_and_reconnect
    sleep $1
    loop $1
}

# Check VE
if hash qm 2>/dev/null
then BACKEND='proxmox'
else BACKEND='libvirt'
fi

# Getopts
if [ ! -z "$2" ] && [ "$2" != '-v' ]; then
    TIMEOUT="$2"
    [ "$1" == '-v' ] && DEBUG=true
elif [ ! -z "$1" ] && [ "$1" != '-v' ]; then
    TIMEOUT="$1"
    [ "$2" == '-v' ] && DEBUG=true
fi

# Start loop
loop ${TIMEOUT:-10}
