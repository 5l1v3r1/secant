#!/usr/bin/env bash

usage()
{
    print_ascii_art
    echo "usage: $0 [-ht] [-d directory]"
}

# Set some default values
TEST_RUN="no"
SECANT_PATH=$(dirname $0)

CONFIG_DIR=${SECANT_CONFIG_DIR:-/etc/secant}
source ${CONFIG_DIR}/secant.conf

source ${SECANT_PATH}/include/functions.sh

while [[ $# -gt 0 ]]; do
    case "$1" in
    -d|--report-dir)
        REPORT_DIR="$2"
        shift
        shift
        ;;
    -h|--help)
        usage
        exit 0
        shift
        ;;
    -t|--test-run)
        TEST_RUN="yes"
        shift
        ;;
    *)
        usage
        exit 1
        ;;
    esac
done

[ -z "$REPORT_DIR" ] && REPORT_DIR="$STATE_DIR/reports"

logging "SECANT" "Starting" "INFO"

cloud_init

onetemplate list > /tmp/templates.$$
ret=$?
trap "rm -f /tmp/templates.$$" EXIT
if [ $ret -ne 0 ]; then
    logging "SECANT" "Failed to retrieve templates (check authentication)" "ERROR"
    exit 1
fi
TEMPLATES=($(awk '{ print $1 }' /tmp/templates.$$ | sed '1d'))

query='//CLOUDKEEPER_APPLIANCE_MPURI' # attribute which determines which template should be analyzed
TEMPLATES_FOR_ANALYSIS=()
for TEMPLATE_ID in "${TEMPLATES[@]}"
do
    NIFTY_ID=$(onetemplate show $TEMPLATE_ID -x | xmlstarlet sel -t -v "$query")
    if [ -n "$NIFTY_ID" ]; then
        TEMPLATES_FOR_ANALYSIS+=($TEMPLATE_ID)
    fi
done

if [ ${#TEMPLATES_FOR_ANALYSIS[@]} -eq 0 ]; then
    logging "SECANT" "No templates for analysis." "INFO"
    exit 0
fi

for TEMPLATE_ID in "${TEMPLATES_FOR_ANALYSIS[@]}"; do
    if [[ $TEMPLATE_ID =~ ^[0-9]+$ ]] ; then
        TEMPLATE_IDENTIFIER=$(onetemplate show $TEMPLATE_ID -x | xmlstarlet sel -t -v "//CLOUDKEEPER_APPLIANCE_ID")
        BASE_MPURI=$(onetemplate show $TEMPLATE_ID -x | xmlstarlet sel -t -v '//CLOUDKEEPER_APPLIANCE_ATTRIBUTES' | base64 -d | jq '.["ad:base_mpuri"]'|sed -e '1,$s/"//g')
        (
            FOLDER_PATH=$REPORT_DIR/$TEMPLATE_IDENTIFIER
            if [[ -d $FOLDER_PATH ]] ; then
                i=1
                while [[ -d $FOLDER_PATH-$i ]]; do
                    let i++
                done
                FOLDER_PATH=$FOLDER_PATH-$i
            fi
            mkdir -p "$FOLDER_PATH" || exit 1

            logging $TEMPLATE_IDENTIFIER "Starting analysis (BASE_MPURI = $BASE_MPURI) template_id == $TEMPLATE_ID." "INFO"
            analyse_template "$TEMPLATE_ID" "$TEMPLATE_IDENTIFIER" "$BASE_MPURI" "$FOLDER_PATH" > ${FOLDER_PATH}/analysis_output.stdout
            if [ $? -ne 0 ]; then
                logging "$TEMPLATE_ID" "Analysis finished with errors (BASE_MPURI = $BASE_MPURI)." "ERROR"
                exit 1
            fi

            logging $TEMPLATE_IDENTIFIER "Analysis completed successfully (BASE_MPURI = $BASE_MPURI), check ${FOLDER_PATH}/analysis_output.{stdout,stderr} for artifacts." "INFO"

            sed '/^$/d' $FOLDER_TO_SAVE_REPORTS/report > $FOLDER_TO_SAVE_REPORTS/report.xml
            rm -f $FOLDER_TO_SAVE_REPORTS/report

            python ${SECANT_PATH}/lib/assessment.py "$TEMPLATE_IDENTIFIER" "$FOLDER_TO_SAVE_REPORTS/report.xml" "$VERSION" "$BASE_MPURI" >> $FOLDER_PATH/assessment_result.xml

            [ "$DELETE_TEMPLATES" = "yes" ] && delete_template_and_images $TEMPLATE_ID
            [ "$TEST_RUN" = "yes" ] || python ${SECANT_PATH}/lib/argo_communicator.py --mode push --niftyID $TEMPLATE_IDENTIFIER --path $FOLDER_PATH/assessment_result.xml --base_mpuri $BASE_MPURI
        ) &
    fi
done

wait
