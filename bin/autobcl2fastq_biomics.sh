#!/bin/bash
set -euo pipefail

VERSION=0.6.2
SCRIPTPATH="$( cd -- "$(dirname $(dirname "$0"))" >/dev/null 2>&1 ; pwd -P )" # absolute script path, handling symlinks, spaces and hyphens
RUNHASH=""
# URL="https://dl.pasteur.fr/fop/C9V4VBVF/230516_VH00537_116_AACLHW3M5__Wed_May_17_10h56m50_2023.tar"

## ------------------------------------------------------------------
## ------------------- HELPER FUNCTIONS -----------------------------
## ------------------------------------------------------------------

## - Usage help
function usage {
    echo -e "Written by J. Serizay"
    echo -e ""
    echo -e "For manual demux of Biomics data: "
    echo -e "--------------------------- "
    echo -e "This requires a SSH config file with a sftpcampus access set up"
    echo -e ""
    echo -e "Usage: $0 [ OPTIONAL ARGUMENTS ] --url <URL>"
    echo -e ""
    echo -e "   --email <EMAIL>                  | Default: jaseriza@pasteur.fr"
    echo -e "                                        Email address for notifications."
    echo -e ""
    echo -e "   --ssh_hostname <SSH_HOSTNAME>    | Default: sftpcampus"
    echo -e "                                        Alias for access to sftpcampus set up in your ~/.ssh/config."
    echo -e ""
    echo -e "   --reads_dir <DESTINATION>        | Default: /pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/"
    echo -e "                                        Directory where the reads are going to be copied (available from sftpcampus)."
    echo -e ""
    echo -e "   --working_dir <WORKING_DIR>      | Default: /pasteur/appa/scratch/jaseriza/autobcl2fastq/"
    echo -e "                                        Directory where demultiplexing takes place (available from maestro)."
    echo -e "                                        Samplesheets are going to be formatted and backed up here."
    echo -e ""
    echo -e "   --sbatch_dir <SBATCH_DIR>        | Default: /opt/hpc/slurm/current/bin/"
    echo -e "                                        Directory for sbatch dependency."
    echo -e ""
    echo -e "   --url <URL>                      | The link provided by Biomics to download sequencing data."
    echo -e ""
    echo -e ""
}

## - Create an Illumina sample sheet using info from an LOCAL Rsg sample sheet
function fix_local_samplesheet {
    if ( test ! -d "${WORKING_DIR}"/samplesheets/ ) ; then
        mkdir "${WORKING_DIR}"/samplesheets/
    fi
    if ( test ! -d "${WORKING_DIR}"/rsgsheets/ ) ; then
        mkdir "${WORKING_DIR}"/rsgsheets/
    fi
    local OUTPUT_FILE="${1}"
    local TEMP_CSV="${WORKING_DIR}/rsgsheets/rsgsheet_${RUNHASH}_fixed.csv"

    # Load indices into associative arrays
    declare -A i7_map i5_map
    while IFS=$'\t' read -r barcode_well i7_sequence i5_sequence; do
        i7_map["$barcode_well"]="$i7_sequence"
        i5_map["$barcode_well"]="$i5_sequence"
    done < <(tail -n +2 "${BASE_DIR}"/indices.txt)

    # Create temporary CSV by joining samplesheet with indices
    {
        echo "Sample_ID,Sample_Name,Sample_Plate,Sample_Well,I7_Index_ID,index,I5_Index_ID,index2,Sample_Project"
        while IFS=$'\t' read -r sample_id barcode_well; do
            # Extract project name: remove everything from first digit onwards
            project=$(echo "$sample_id" | sed 's/[0-9].*//')
            i7="${i7_map[$barcode_well]}"
            i5="${i5_map[$barcode_well]}"
            echo "$sample_id,$sample_id,,$barcode_well,,$i7,,$i5,$project"
        done < "${SAMPLESHEET}"
    } > "${TEMP_CSV}"
    
    cat > "${OUTPUT_FILE}" << EOF
[Header]
Date,${RUNDATE}
Workflow,GenerateFASTQ
Experiment Name,NSQ${RUNNB}

[Data]
EOF

    # Append fixed samplesheet
    cat "${TEMP_CSV}" >> "${OUTPUT_FILE}"

    ## -------- Check that all users detected in the samplesheet are already registered in `users.conf`. 
    USERS_CONFIG="${BASE_DIR}"/users.conf
    LISTED_USERS_IDS=$(tail -n +2 "${TEMP_CSV}" | cut -d',' -f9 | sort | uniq)
    UNREGISTERED_IDS=""
    for USER in $LISTED_USERS_IDS
    do
        if ! grep -q "^\[${USER}\]" "${USERS_CONFIG}"; then
            UNREGISTERED_IDS="${UNREGISTERED_IDS} ${USER}"
        fi
    done
    if [ -n "${UNREGISTERED_IDS}" ]; then
        msg="The following user(s) are not registered yet:\n\n${UNREGISTERED_IDS}\n\nPlease fill in ${USERS_CONFIG} before re-attempting to demultiplex."
        email_error "${msg}"
        echo -e "${msg}"
        rm -rf "${WORKING_DIR}"/rsgsheets/
        exit 1
    fi

    ## -------- Check that all indices provided are listed in `indices.txt`
    INDICES="${BASE_DIR}"/indices.txt
    LISTED_INDICES=`sed '1d' "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv | sed 's/^[^,]*,[^,]*,,//' | sed 's/,.*//'`
    REGISTERED_INDICES=`sed 's,\s.*,,' ${INDICES}`
    UNREGISTERED_INDICES=""
    for INDEX in $LISTED_INDICES
    do
        if ( test `grep $INDEX ${INDICES} | wc -l` -eq 0 ) ; then
            UNREGISTERED_INDICES="${UNREGISTERED_INDICES} ${INDEX}"
        fi
    done
    if ( test -n "${UNREGISTERED_INDICES}" ) ; then
        msg="The following index(es) are not registered yet:\n\n${UNREGISTERED_INDICES}\n\nPlease fill in ${INDICES} before re-attempting to demultiplex."
        email_error "${msg}"
        echo -e "${msg}"
        rm -rf "${WORKING_DIR}"/rsgsheets/
        exit 1
    fi

    rm -rf "${WORKING_DIR}"/rsgsheets/
}

## - Email notification
function email_start {
    SAMPLES=$(cat "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' ')
    echo -e "Run ${RUN} started @ $(date)\npath: ${SOURCE}\nsamples: ${SAMPLES}" | mailx \
        -s "[CLUSTER INFO] Submitted run ${RUN} to autobcl2fastq" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv \
        "${EMAIL}"
}
function email_error {
    echo -e "${1}" | mailx \
        -s "[CLUSTER INFO] ERROR run ${RUN} to autobcl2fastq" \
        "${EMAIL}"
}

## - Logging function
function fn_log {
    echo -e "`date "+%y-%m-%d %H:%M:%S"` [INFO] $@"
}

## - Clean up function
function cleanup() {
    local status=$?
    if ( test "${status}" -gt 0 ) ; then
        echo "Caught signal ${status} ... cleaning up & quitting."
        rm -f ${WORKING_DIR}/PROCESSING
        rm -f ${WORKING_DIR}/SAMPLESHEETS_TO_PROCESS
    fi
    exit 0
}

## ------------------------------------------------------------------
## -------- PARSING ARGUMENTS ---------------------------------------
## ------------------------------------------------------------------

# Default values of arguments

EMAIL=jaseriza@pasteur.fr
SENDER=ekornobi@pasteur.fr
SUBJECT="Biomics downloadable link"
URL=""
SSH_HOSTNAME=sftpcampus
DESTINATION=/pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/ # Where the fastq are written at the end, should be `Rsg_reads/nextseq_runs` [HAS TO BE MOUNTED ON SFTPCAMPUS]
WORKING_DIR=/pasteur/appa/scratch/jaseriza/autobcl2fastq/ # Where the bcl files are processed into fastq, ideally a fast scratch
SBATCH_DIR=/opt/hpc/slurm/current/bin/ # Directory to sbatch bin
MICROMAMBA_BIN=/pasteur/appa/homes/jaseriza/.local/bin/micromamba
SLURM_PARTITION="common,dedicated"
SLURM_QOS="fast"
BASE_DIR="${SCRIPTPATH}" # Where the script is hosted, should be in:
# BASE_DIR=/pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq

for arg in "$@"
do
    case $arg in
        #####
        ##### Basic arguments
        #####
        --email)
        EMAIL="${2}"
        shift 
        shift 
        ;;
        --ssh_hostname)
        SSH_HOSTNAME="${2}"
        shift 
        shift 
        ;;
        --reads_dir)
        DESTINATION="${2}"
        shift 
        shift 
        ;;
        --working_dir)
        WORKING_DIR="${2}"
        shift 
        shift 
        ;;
        --sbatch_dir)
        SBATCH_DIR="${2}"
        shift 
        shift 
        ;;
        #####
        ##### Manual mode
        #####
        --url)
        URL="${2}"
        shift 
        shift 
        ;;
        #####
        ##### BASIC ARGUMENTS
        #####
        -h|--help)
        usage && exit 0
        ;;
        -v|--version)
        echo -e "autobcl2fastq v${VERSION}" && exit 0
        ;;
    esac
done

## ------------------------------------------------------------------
## ------------------- CLEAN UP BEFORE EXIT -------------------------
## ------------------------------------------------------------------

trap cleanup EXIT INT TERM

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

fn_log "cmd: ${0}"

## - Checking that no process is currently on going, immediately abort otherwise
fn_log "Checking that no process is currently on going"
if ( test -f "${WORKING_DIR}"/PROCESSING || test `${SBATCH_DIR}/sacct --format=Jobname%35,state | grep 'NS500150' | grep -v COMPLETED | grep -v CANCELLED | grep -v FAILED | wc -l` -gt 0 ) ; then
    echo "Samples currently being processed. Aborting now."
    exit 0
fi

## - Check whether a Biomics run link has been manually provided/sent by email
if ( test -z "${URL}" ) ; then
    fn_log "No run URL manually provided, checking email inbox for new run link"
    URL=$("${MICROMAMBA_BIN}" run -n autobcl2fastq ${BASE_DIR}/bin/check_emails.py --username "${EMAIL}" --sender "${SENDER}" --subject "${SUBJECT}")
    if ( test -z "${URL}" ) ; then
        fn_log "No new run URL found in email inbox. Exiting now."
        exit 0
    fi
fi
fn_log "Continuing with run URL: ${URL}"

## - Download run sample sheet from rsgteams
RUN=`basename ${URL} | sed 's,__.*,,'`
RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
SEQID=`echo "${RUN}" | sed "s,.*${RUNDATE}_,,g" | sed "s,_.*,,g"`
RUNNB=`echo "${RUN}" | sed "s,.*${SEQID}_,,g" | sed "s,_.*,,g"`
RUNHASH=`echo "${RUN}" | sed "s,.*${RUNNB}_,,g" | sed "s,_.*,,g"`
SOURCE="${WORKING_DIR}/runs/"
echo "${RUN}" > "${WORKING_DIR}"/PROCESSING

## - Check that the samplesheet exists
SAMPLESHEET=$("${MICROMAMBA_BIN}" run -n autobcl2fastq ${BASE_DIR}/bin/check_samplesheets.py --hash ${RUNHASH} --email ${EMAIL} --sharepoint-url "https://pasteurfr.sharepoint.com/sites/RSGteam" --entrypoint "/sites/RSGteam/Documents partages/Experimentalist group/sequencing_runs/" --samplesheets-folder ${WORKING_DIR}/samplesheets_raw/)
if ( test ! -f "${SAMPLESHEET}" ) ; then
    msg="The samplesheet for run ${RUN} could not be found at path: ${SAMPLESHEET}\n\nPlease check and re-attempt to demultiplex."
    email_error "${msg}"
    echo -e "${msg}"
    exit 1
fi
fn_log "Using the local samplesheet: ${SAMPLESHEET}"
fix_local_samplesheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv
fn_log "Fixed sample sheet created at: ${WORKING_DIR}/samplesheets/SampleSheet_${RUNDATE}_${RUNNB}_${RUNHASH}.csv"
echo -e ""
cat "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv
echo -e ""

## - Download run raw data
RUN_TAR_FILE="${WORKING_DIR}/runs/`basename ${URL}`"
fn_log "Downloading raw data from Biomics to: ${RUN_TAR_FILE}"
if [ -f "${RUN_TAR_FILE}" ]; then
    curl -L -z "${RUN_TAR_FILE}" "${URL}" -o "${RUN_TAR_FILE}"
else
    curl -L "${URL}" -o "${RUN_TAR_FILE}"
fi
tar -xf "${RUN_TAR_FILE}" --directory "${WORKING_DIR}"/runs/

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN ---------------------------
## ------------------------------------------------------------------

## - Notify start of new run being processed
email_start

## - Process run
## |--- Fix sample sheet
## |--- Run bcl2fastq, fastqc, fastq_screen, multiQC 
## |--- Copy fastq reads to Rsg_reads
## |--- Copy reports to Rsg_reads/reports
## |--- Enable Read/Write for all files

fn_log "Processing run ${RUN}"
"${SBATCH_DIR}"/sbatch \
    --partition "${SLURM_PARTITION}" \
    --qos "${SLURM_QOS}" \
    -J "${RUN}" \
    -o "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".out \
    -e "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".err \
    --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",WORKING_DIR="${WORKING_DIR}",RUN="${RUN}",EMAIL="${EMAIL}",DESTINATION="${DESTINATION}" \
    "${BASE_DIR}/bin/process_run_biomics.sh"

rm "${RUN_TAR_FILE}"
exit 0
