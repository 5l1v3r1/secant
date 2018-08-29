#!/usr/bin/env bash
# $1 : secant conf file path

#SECANT_CONF_PATH=${1-$DEFAULT_SECANT_CONF_PATH}
#source "$SECANT_CONF_PATH"

SECANT_STATUS_OK="OK"
SECANT_STATUS_FAILED="ERROR"
SECANT_STATUS_SKIPPED="SKIPPED"
SECANT_STATUS_500="INTERNAL_FAILURE"

delete_template_and_images()
{
    TEMPLATE_IDENTIFIER=$1

    timeout=$((SECONDS+(5*60)))
    while true; do
        if [ $SECONDS -gt $timeout ]; then
            logging $TEMPLATE_IDENTIFIER "Time-out reached while waiting for the VM to finish before deleting, exiting." "ERROR"
            return 1
        fi
        VM_IDS=($(cloud_get_vm_ids))
        found="no"
        for VM_ID in "${VM_IDS[@]}"; do
            templ_id=$(cloud_vm_query "$VM_ID" "//TEMPLATE_ID")
            [ "$templ_id" = "$TEMPLATE_IDENTIFIER" ] && found="yes"
        done
        [ "$found" = "no" ] && break
        sleep 10
    done

	# Get Template Images
	images=()
	while IFS= read -r entry; do
	  images+=( "$entry" )
	done < <(cloud_template_query "$TEMPLATE_ID" "//DISK/IMAGE_ID/text()")

	for image_name in "${images[@]}"
	do
	    DELETE_IMAGE_RESULT=$(cloud_delete_image "$image_name")
	    if [[ ! -n  $DELETE_IMAGE_RESULT ]]
	    then
	        logging $TEMPLATE_IDENTIFIER "Image: $image_name successfully deleted." "DEBUG"
	    else
            CHECK_FOR_IMAGE_MANAGE_ERROR=$(echo $DELETE_IMAGE_RESULT | grep -o "Not authorized to perform MANAGE IMAGE \[.[0-9]*\]")
            if [[ -n $CHECK_FOR_IMAGE_MANAGE_ERROR ]]
            then
                logging $TEMPLATE_IDENTIFIER "Secant user is not authorized to delete image: $(echo $CHECK_FOR_IMAGE_MANAGE_ERROR | grep -o '[0-9]*')." "ERROR"
            fi
        fi
	done

    DELETE_TEMPLATE_RESULT=$(cloud_delete_template "$TEMPLATE_ID")
    if [[ ! -n  $DELETE_TEMPLATE_RESULT ]]
	then
	    logging $TEMPLATE_IDENTIFIER "Template: $TEMPLATE_ID successfully deleted." "DEBUG"
    else
        CHECK_FOR_TEMPLATE_MANAGE_ERROR=$(echo $DELETE_TEMPLATE_RESULT | grep -o "Not authorized to perform MANAGE TEMPLATE \[.[0-9]*\]")
        if [[ -n $CHECK_FOR_TEMPLATE_MANAGE_ERROR ]]
        then
            logging $TEMPLATE_IDENTIFIER "Secant user is not authorized to delete template: $(echo $CHECK_FOR_TEMPLATE_MANAGE_ERROR | grep -o '[0-9]*')." "ERROR"
        fi
    fi
}

clean_if_analysis_failed() {
    VM_IDS=($(cloud_get_vm_ids))
    for VM_ID in "${VM_IDS[@]}"
    do
        NIFTY_ID=$(cloud_vm_query $VM_ID "//NIFTY_APPLIANCE_ID" | tr -d '\n')
        if [ -n "$NIFTY_ID" ]; then # n - for not empty
            if [[ $NIFTY_ID == $1 ]]; then
                cloud_shutdown_vm "$VM_ID"
            fi
        fi
    done
}

logging() {
    local log=$log_file

    if [ "$3" == "DEBUG" -a "$DEBUG" != "true" ]; then
        return 0
    fi

    if [ -z "$log" ]; then
        echo `date +"%Y-%d-%m %H:%M:%S"` "[$1] ${3}: $2"
    else
        echo `date +"%Y-%d-%m %H:%M:%S"` "[$1] ${3}: $2" >> $log;
    fi
}

print_ascii_art(){
cat << "EOF"
     _______. _______   ______     ___      .__   __. .___________.
    /       ||   ____| /      |   /   \     |  \ |  | |           |
   |   (----`|  |__   |  ,----'  /  ^  \    |   \|  | `---|  |----`
    \   \    |   __|  |  |      /  /_\  \   |  . `  |     |  |
.----)   |   |  |____ |  `----./  _____  \  |  |\   |     |  |
|_______/    |_______| \______/__/     \__\ |__| \__|     |__|
EOF
}

remote_exec()
{
    HOST=$1
    USER=$2
    CMD=$3
    IN=$4
    OUT=$5

    SSH="ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey"


    if [ -n "$USER" ]; then   
        $SSH ${USER}@${HOST} "$CMD" < $IN > $OUT
        [ $? -eq 0 ] && return 0
    fi
    for u in secant centos ubuntu; do
        $SSH ${u}@${HOST} "$CMD" < $IN > $OUT
        [ $? -eq 0 ] && return 0
    done

    return 1
}

perform_check()
{
    TEMPLATE_IDENTIFIER=$1
    VM_ID=$2
    FOLDER_TO_SAVE_REPORTS=$3
    PROBE=$4
    shift 4
    ipAddresses=("${@}")

    (
        ${SECANT_PATH}/probes/$PROBE/main "${ipAddresses[0]}" "$FOLDER_TO_SAVE_REPORTS" "$TEMPLATE_IDENTIFIER" > $FOLDER_TO_SAVE_REPORTS/"$PROBE".stdout
        if [ $? -ne 0 ]; then
            logging $TEMPLATE_IDENTIFIER "Probe '$PROBE' failed to finish correctly" "ERROR"
            (echo $SECANT_STATUS_500; echo "Probe $PROBE failed to finish correctly") | ${SECANT_PATH}/tools/reporter.py "$PROBE" >> $FOLDER_TO_SAVE_REPORTS/report || exit 1
            # we suppress the errors in probing scripts and don;t return error status
            exit 0
        fi
        ${SECANT_PATH}/tools/reporter.py "$PROBE" < $FOLDER_TO_SAVE_REPORTS/"$PROBE".stdout >> $FOLDER_TO_SAVE_REPORTS/report || exit 1
    )
    if [ $? -ne 0 ]; then
        logging $TEMPLATE_IDENTIFIER "Internal error while processing '$PROBE'" "ERROR"
        echo $SECANT_STATUS_500 | ${SECANT_PATH}/tools/reporter.py "$PROBE" >> $FOLDER_TO_SAVE_REPORTS/report
        return 1
    fi

    return 0
}

analyse_machine()
{
    CONFIG_DIR=${SECANT_CONFIG_DIR:-/etc/secant}
    source $CONFIG_DIR/probes.conf

    TEMPLATE_IDENTIFIER=$1
    VM_ID=$2
    FOLDER_TO_SAVE_REPORTS=$3
    shift 3
    ipAddresses=("${@}")

    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $FOLDER_TO_SAVE_REPORTS/report
    echo "<SECANT>" >> $FOLDER_TO_SAVE_REPORTS/report
    if [ -n "$SECANT_PROBES" ]; then
        IFS=',' read -ra PROBES <<< "$SECANT_PROBES"
        for PROBE in "${PROBES[@]}"; do
            perform_check "$TEMPLATE_IDENTIFIER" "$VM_ID" "$FOLDER_TO_SAVE_REPORTS" "$PROBE" "${ipAddresses[@]}"
        done
    fi

#    echo "<DATE>$(date +%s)</DATE>" >> $FOLDER_TO_SAVE_REPORTS/report
    echo "</SECANT>" >> $FOLDER_TO_SAVE_REPORTS/report
}

analyse_template()
{
    TEMPLATE_ID=$1
    TEMPLATE_IDENTIFIER=$2
    BASE_MPURI=$3
    FOLDER_PATH=$4

    CTX_ADD_USER=${SECANT_PATH}/conf/ctx.add_user_secant

    FOLDER_TO_SAVE_REPORTS=
    VM_ID=
    logging $TEMPLATE_IDENTIFIER "Start first run without contextualization script." "DEBUG"
    #Folder to save reports and logs during first run
    FOLDER_TO_SAVE_REPORTS=$FOLDER_PATH/1
    mkdir -p $FOLDER_TO_SAVE_REPORTS
    VM_ID=$(cloud_start_vm "$TEMPLATE_ID" "$CTX_ADD_USER")

    if [[ $VM_ID =~ ^VM[[:space:]]ID:[[:space:]][0-9]+$ ]]; then
        VM_ID=$(echo $VM_ID | egrep -o '[0-9]+$')
        logging $TEMPLATE_IDENTIFIER "Template successfully instantiated, VM_ID: $VM_ID" "DEBUG"
    else
        logging $TEMPLATE_IDENTIFIER "$VM_ID." "ERROR"
        return 1
    fi

    # make sure VM is put down on exit (regardless how the function finishes)
    trap "cloud_shutdown_vm "$VM_ID"; trap - RETURN" RETURN

    lcm_state=$(cloud_vm_query "$VM_ID" "//LCM_STATE/text()")
    if [ $? -ne 0 ]; then
        logging "Couldn't query //LCM_STATE/text() on vm with id $VM_ID."
        exit 1
    fi
    vm_name=$(cloud_vm_query "$VM_ID" "//NAME/text()")
    if [ $? -ne 0 ]; then
        logging "Couldn't query //NAME/text() on vm with id $VM_ID."
        exit 1
    fi

    # Wait for Running status
    beginning=$(date +%s)
    while [ $lcm_state -ne 3 ]
    do
        now=$(date +%s)
        if [ $((now - beginning)) -gt $((60 * 30)) ]; then
            logging $TEMPLATE_IDENTIFIER "VM hasn't switched to the running status within 30 mins, exiting" "ERROR"
            return 1
        fi
        sleep 5s
        lcm_state=$(cloud_vm_query "$VM_ID" "//LCM_STATE/text()")
    done

    logging $TEMPLATE_IDENTIFIER "Virtual Machine $vm_name is now running." "DEBUG"

    # Get IPs
    ipAddresses=()
    while IFS= read -r entry; do
        ipAddresses+=( "$entry" )
    done < <(cloud_vm_query "$VM_ID" "//NIC/IP/text()")
    if [ ${#ipAddresses[*]} -lt 1 ]; then
        logging $TEMPLATE_IDENTIFIER "The machine hasn't been assigned any IP address, exiting" "ERROR"
        return 1
    fi

    # Wait 80 seconds befor first test
    sleep 140

    analyse_machine "$TEMPLATE_IDENTIFIER" "$VM_ID" "$FOLDER_TO_SAVE_REPORTS" "${ipAddresses[@]}"
    if [ $? -ne 0 ]; then
        logging $TEMPLATE_IDENTIFIER "Machine analysis didn't finish correctly" "ERROR"
        FAIL=yes
    fi

    if [ -z "$FAIL" ]; then
        return 0
    else
        return 1
    fi
}
