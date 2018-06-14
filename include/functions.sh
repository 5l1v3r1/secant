#!/usr/bin/env bash
# $1 : secant conf file path

#SECANT_CONF_PATH=${1-$DEFAULT_SECANT_CONF_PATH}
#source "$SECANT_CONF_PATH"

SECANT_STATUS_OK="OK"
SECANT_STATUS_FAILED="ERROR"
SECANT_STATUS_SKIPPED="SKIPPED"
SECANT_STATUS_500="INTERNAL_FAILURE"

cloud_init()
{
    # only ON is supported atm
    CONFIG_DIR=${SECANT_CONFIG_DIR:-/etc/secant}
    source ${CONFIG_DIR}/cloud.conf

    export ONE_HOST ONE_XMLRPC
}

shutdown_vm()
{
    VM_ID=$1
    onevm shutdown --hard $VM_ID
    if [ $? -ne 0 ]; then
        logging $TEMPLATE_IDENTIFIER "Failed to shutdown VM $VM_ID." "ERROR"
    fi
}



logging() {
    local log=$log_file
    [ -n "$log" ] || log=/dev/stdout

    if [[ $3 == "INFO" ]]; then
        echo `date +"%Y-%d-%m %H:%M:%S"` "[$1] INFO: $2" >> $log;
    fi

    if [[ $3 == "ERROR" ]]; then
        echo `date +"%Y-%d-%m %H:%M:%S"` "[$1] ERROR: $2" >> $log;
    fi

    if [[ $3 == "DEBUG" ]] && [ "$DEBUG" = "true" ]; then
        echo `date +"%Y-%d-%m %H:%M:%S"` "[$1] DEBUG: $2" >> $log;
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

    $SSH ${USER}@${HOST} "$CMD" < $IN > $OUT
    [ $? -eq 0 ] && return 0

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
    CHECK_DIR=$4
    shift 4
    ipAddresses=("${@}")

    (
        cd $CHECK_DIR || exit 1
        name=$(./get_name) || exit 1
        ./main.sh "${ipAddresses[0]}" "$FOLDER_TO_SAVE_REPORTS" "$TEMPLATE_IDENTIFIER" > $FOLDER_TO_SAVE_REPORTS/"$name".stdout
        if [ $? -ne 0 ]; then
            logging $TEMPLATE_IDENTIFIER "Probe $CHECK_DIR failed to finish correctly" "ERROR"
            echo $SECANT_STATUS_500 | ../../lib/reporter.py "$name" >> $FOLDER_TO_SAVE_REPORTS/report || exit 1
            # we suppress the errors in probing scripts and don't return error status (so we're more robust)
        else
            ../../lib/reporter.py "$name" < $FOLDER_TO_SAVE_REPORTS/"$name".stdout >> $FOLDER_TO_SAVE_REPORTS/report || exit 1
        fi
    )
    if [ $? -ne 0 ]; then
        logging $TEMPLATE_IDENTIFIER "Internal error while processing $CHECK_DIR" "ERROR"
        echo $SECANT_STATUS_500 | ../../lib/reporter.py "$name" >> $FOLDER_TO_SAVE_REPORTS/report
        return 1
    fi

    return 0
}

analyse_machine()
{
    TEMPLATE_IDENTIFIER=$1
    VM_ID=$2
    FOLDER_TO_SAVE_REPORTS=$3
    shift 3
    ipAddresses=("${@}")

    echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $FOLDER_TO_SAVE_REPORTS/report
    echo "<SECANT>" >> $FOLDER_TO_SAVE_REPORTS/report

    logging $TEMPLATE_IDENTIFIER "Starting external tests..." "DEBUG"
    for filename in $EXTERNAL_TESTS_FOLDER_PATH/*/; do
        perform_check "$TEMPLATE_IDENTIFIER" "$VM_ID" "$FOLDER_TO_SAVE_REPORTS" "$filename" "${ipAddresses[@]}"
        [ $? -eq 0 ] || return 1
    done

    number_of_attempts=0
    ip_address_for_ssh=
    while [ -z "$ip_address_for_ssh" ] && [ $number_of_attempts -lt 15 ]; do
        ip_address_for_ssh=""
        for ip in "${ipAddresses[@]}"; do
            ssh_state=$(nmap $ip -PN -p ssh | egrep -o 'open|closed|filtered')
            if [ "$ssh_state" == "open" ]; then
                logging $TEMPLATE_IDENTIFIER "Open SSH port has been successfully detected, IP address: $ip" "DEBUG"
                ip_address_for_ssh=$ip
                break;
            fi
        done
        if [ -z "$ip_address_for_ssh" ]; then
            ((number_of_attempts++))
            sleep 5s
        fi
    done

    #Run internal tests
    if [ -z "$ip_address_for_ssh" ]; then
        logging $TEMPLATE_IDENTIFIER "Open SSH port has not been detected, skip internal tests." "DEBUG"
        for filename in $INTERNAL_TESTS_FOLDER_PATH/*/; do
            (name=$($filename/get_name) && echo $SECANT_STATUS_SKIPPED | ../lib/reporter.py $name >> $FOLDER_TO_SAVE_REPORTS/report)
        done
    else
        LOGIN_AS_USER="root"
        ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o PreferredAuthentications=publickey "$ip_address_for_ssh" 2&> /tmp/ssh_out.$$
        SUGGESTED_USER=$(cat /tmp/ssh_out.$$ | grep -i "Please login as the user*" | sed -e 's/Please login as the user \"\(.*\)\" rather than the user \"root\"./\1/')
        rm -f /tmp/ssh_out.$$
        if [ ! -z "$SUGGESTED_USER" ]; then
            LOGIN_AS_USER="$SUGGESTED_USER"
        fi
        logging $TEMPLATE_IDENTIFIER "Starting internal tests... IP: $ip_address_for_ssh, login as user: $LOGIN_AS_USER" "DEBUG"
        for filename in $INTERNAL_TESTS_FOLDER_PATH/*/; do
            perform_check "$TEMPLATE_IDENTIFIER" "$VM_ID" "$FOLDER_TO_SAVE_REPORTS" "$filename" "${ipAddresses[@]}"
            [ $? -eq 0 ] || return
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

    # Move to secant core (?):
    # Check from which folder script is running
    CURRENT_DIRECTORY=${PWD##*/}
    EXTERNAL_TESTS_FOLDER_PATH=
    INTERNAL_TESTS_FOLDER_PATH=

    if [[ "$CURRENT_DIRECTORY" == "lib" ]] ; then
        EXTERNAL_TESTS_FOLDER_PATH=../external_tests
        INTERNAL_TESTS_FOLDER_PATH=../internal_tests
        LIB_FOLDER_PATH=""
        source ../include/functions.sh
        RUN_WITH_CONTEXT_SCRIPT_PATH=run_with_contextualization.sh
        CTX_ADD_USER=ctx.add_user_secant
        CHECK_IF_CLOUD_INIT_RUN_FINISHED_SCRIPT_PATH=check_if_cloud_init_run_finished.py
    else
        EXTERNAL_TESTS_FOLDER_PATH=external_tests
        INTERNAL_TESTS_FOLDER_PATH=internal_tests
        source include/functions.sh
        LIB_FOLDER_PATH="lib"
        RUN_WITH_CONTEXT_SCRIPT_PATH=lib/run_with_contextualization.sh
        CTX_ADD_USER=lib/ctx.add_user_secant
        CHECK_IF_CLOUD_INIT_RUN_FINISHED_SCRIPT_PATH=lib/check_if_cloud_init_run_finished.py
    fi

    FOLDER_TO_SAVE_REPORTS=
    VM_ID=
    for RUN_WITH_CONTEXT_SCRIPT in false #true
    do
        if ! $RUN_WITH_CONTEXT_SCRIPT; then
            logging $TEMPLATE_IDENTIFIER "Start first run without contextualization script." "DEBUG"
            #Folder to save reports and logs during first run
            FOLDER_TO_SAVE_REPORTS=$FOLDER_PATH/1
            mkdir -p $FOLDER_TO_SAVE_REPORTS
            VM_ID=$(onetemplate instantiate $TEMPLATE_ID $CTX_ADD_USER)
        else
            logging $TEMPLATE_IDENTIFIER "Start second run with contextualization script." "DEBUG"
            #Folder to save reports and logs during second run
            FOLDER_TO_SAVE_REPORTS=$FOLDER_PATH/2
            mkdir -p $FOLDER_TO_SAVE_REPORTS
            RETURN_MESSAGE=$(./$RUN_WITH_CONTEXT_SCRIPT_PATH $TEMPLATE_ID $TEMPLATE_IDENTIFIER $FOLDER_TO_SAVE_REPORTS)
            if [[ "$RETURN_MESSAGE" == "1" ]]; then
                logging $TEMPLATE_IDENTIFIER "Could not instantiate template with contextualization!" "ERROR"
                continue
            fi
            VM_ID=$RETURN_MESSAGE
        fi

        if [[ $VM_ID =~ ^VM[[:space:]]ID:[[:space:]][0-9]+$ ]]; then
            VM_ID=$(echo $VM_ID | egrep -o '[0-9]+$')
            logging $TEMPLATE_IDENTIFIER "Template successfully instantiated, VM_ID: $VM_ID" "DEBUG"
        else
            logging $TEMPLATE_IDENTIFIER "$VM_ID." "ERROR"
            return 1
        fi

        # make sure VM is put down on exit (regardless how the function finishes)
        trap "shutdown_vm $VM_ID; trap - RETURN" RETURN

        lcm_state=$(onevm show $VM_ID -x | xmlstarlet sel -t -v '//LCM_STATE/text()' -n)
        vm_name=$(onevm show $VM_ID -x | xmlstarlet sel -t -v '//NAME/text()' -n)

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
            lcm_state=$(onevm show $VM_ID -x | xmlstarlet sel -t -v '//LCM_STATE/text()' -n)
        done

        logging $TEMPLATE_IDENTIFIER "Virtual Machine $vm_name is now running." "DEBUG"

        # Get IPs
        query='//NIC/IP/text()'
        ipAddresses=()
        while IFS= read -r entry; do
            ipAddresses+=( "$entry" )
        done < <(onevm show $VM_ID -x | xmlstarlet sel -t -v "$query" -n)
        if [ ${#ipAddresses[*]} -lt 1 ]; then
            logging $TEMPLATE_IDENTIFIER "The machine hasn't been assigned any IP address, exiting" "ERROR"
            return 1
        fi

        # Wait 80 seconds befor first test
        sleep 140

        if $RUN_WITH_CONTEXT_SCRIPT;
        then
            # Wait for contextualization
            # TODO edit SUGESTED USER instedad root
            RESULT=$(cat $CHECK_IF_CLOUD_INIT_RUN_FINISHED_SCRIPT_PATH | ssh -q -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o PreferredAuthentications=publickey root@${ipAddresses[0]} python - 2>&1)
            while [[ $RESULT == "1" ]]
            do
                sleep 10
                RESULT=$(cat $CHECK_IF_CLOUD_INIT_RUN_FINISHED_SCRIPT_PATH | ssh -q -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o PreferredAuthentications=publickey root@${ipAddresses[0]} python - 2>&1)
            done
            #logging $TEMPLATE_IDENTIFIER "$RESULT" "DEBUG"
        fi

        analyse_machine "$TEMPLATE_IDENTIFIER" "$VM_ID" "$FOLDER_TO_SAVE_REPORTS" "${ipAddresses[@]}"
        if [ $? -ne 0 ]; then
            logging $TEMPLATE_IDENTIFIER "Machine analysis didn't finish correctly" "ERROR"
            FAIL=yes
        fi

        if [ -z "$FAIL"]; then
            return 0
        else
            return 1
        fi

    done
}
