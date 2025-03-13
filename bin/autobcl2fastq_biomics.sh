#!/bin/bash

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
    echo -e "This requires several dependencies, including: "
    echo -e "   - a SSH config file with a sftpcampus access set up"
    echo -e "   - a rclone config file for access to RSG Teams files (see `--rclone_conf`)"
    echo -e "   - Few extra binaries (see `--bin_dir`)"
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
    echo -e "   --bin_dir <BIN_DIR>              | Default: /pasteur/appa/homes/jaseriza/miniforge/bin/"
    echo -e "                                        Directory for xlsx2csv and Rscript dependencies."
    echo -e ""
    echo -e "   --rclone_conf <RCLONE_CONFIG>    | Default: /pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/rclone.conf"
    echo -e "                                        This file contains credentials to authenticate to RSG Teams repository."
    echo -e ""
    echo -e "   --url <URL>                      | The link provided by Biomics to download sequencing data."
    echo -e ""
    echo -e "   --samplesheet <PATH>             | Provide a local path to the sample sheet."
    echo -e ""
    echo -e ""
}

## - Compare the list of run sheets from RSG Teams folder (shared with the lab) to the list of samplesheets already processed. 
# This requires a custom rsgteams access point set up for `rclone`.
function fetch_samplesheets {
    grep -v -f <(ls "${WORKING_DIR}"/samplesheets/ | sed 's,.*_,,' | sed 's,.csv,,') <("${BIN_DIR}"/rclone lsf rsgteams:'Experimentalist group/sequencing_runs/' --config "${RCLONE_CONFIG}" | grep rsgsheet | grep -v xxx) \
    | sed 's,rsgsheet_,,' | sed 's,.xlsx,,' > "${1}"
}

## - Create an Illumina sample sheet using info from an Rsg sample sheet
function fix_samplesheet {
    "${BIN_DIR}"/rclone copy rsgteams:"Experimentalist group/sequencing_runs/rsgsheet_${RUNHASH}.xlsx" "${WORKING_DIR}"/rsgsheets/ --config "${RCLONE_CONFIG}"
    "${BIN_DIR}"/xlsx2csv "${WORKING_DIR}"/rsgsheets/rsgsheet_${RUNHASH}.xlsx | cut -f 1-8 -d, | grep -v ^, | grep -v ^[0-9]*,, > "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}".csv
    cmds=`echo -e "
    x <- read.csv('"${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}".csv') ;
    y <- read.csv('${BASE_DIR}/indices.txt', header = TRUE, sep = '\\\\\t') ; 
    x <- merge(x, y, by = 'barcode_well', all.x = TRUE) ;
    z <- data.frame(Sample_ID = x\\$sample_id, Sample_Name = x\\$sample_id, Sample_Plate = '', Sample_Well = x\\$barcode_well, I7_Index_ID = '', index = x\\$i7_sequence, I5_Index_ID = '', index2 = x\\$i5_sequence, Sample_Project = gsub('[0-9].*', '', x\\$sample_id)) ;
    write.table(z, '"${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv', quote = FALSE, row.names = FALSE, col.names = TRUE, sep = ',')
    "`
    "${BIN_DIR}"/Rscript <(echo "${cmds}")
    echo "[Header]
    Date,"${RUNDATE}"
    Workflow,GenerateFASTQ
    Experiment Name,NSQ"${RUNNB}"

    [Data]" | sed 's/^[ \t]*//' > "${1}"
    
    ## -------- Check that all users detected in the samplesheet are already registered in `users.conf`. 
    USERS_CONFIG="${BASE_DIR}"/users.conf
    LISTED_USERS_IDS=`sed '1d' "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv | sed 's/.*,//' | sort | uniq`
    REGISTERED_USERS_IDS=`grep '\[' ${USERS_CONFIG} | sed 's,[][],,g'`
    unset UNREGISTERED_IDS
    for USER in $LISTED_USERS_IDS
    do
        if ( test `grep $USER <(grep '\[' ${USERS_CONFIG} | sed 's,[][],,g') | wc -l` -eq 0 ) ; then
            UNREGISTERED_IDS="${UNREGISTERED_IDS} ${USER}"
        fi
    done
    if ( test -n "${UNREGISTERED_IDS}" ) ; then
        msg="The following user(s) are not registered yet:\n\n${UNREGISTERED_IDS}\n\nPlease fill in ${USERS_CONFIG} before re-attempting to demultiplex."
        email_error "${msg}"
        echo -e "${msg}"
        exit 1
    fi

    ## -------- Check that all indices provided are listed in `indices.txt`
    INDICES="${BASE_DIR}"/indices.txt
    LISTED_INDICES=`sed '1d' "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv | sed 's/^[^,]*,[^,]*,,//' | sed 's/,.*//'`
    REGISTERED_INDICES=`sed 's,\s.*,,' ${INDICES}`
    unset UNREGISTERED_INDICES
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
        exit 1
    fi

    ## -------- Copy the fixed samplesheet to the output path
    cat "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv >> "${1}"
    rm -rf "${WORKING_DIR}"/rsgsheets/
}

## - Create an Illumina sample sheet using info from an LOCAL Rsg sample sheet
function fix_local_samplesheet {
    mkdir "${WORKING_DIR}"/rsgsheets/
    cmds=`echo -e "
    x <- read.table('"${samplesheet}"') ;
    colnames(x) <- c('sample_id', 'barcode_well') ;
    y <- read.csv('${BASE_DIR}/indices.txt', header = TRUE, sep = '\\\\\t') ; 
    x <- merge(x, y, by = 'barcode_well', all.x = TRUE) ;
    z <- data.frame(Sample_ID = x\\$sample_id, Sample_Name = x\\$sample_id, Sample_Plate = '', Sample_Well = x\\$barcode_well, I7_Index_ID = '', index = x\\$i7_sequence, I5_Index_ID = '', index2 = x\\$i5_sequence, Sample_Project = gsub('[0-9].*', '', x\\$sample_id)) ;
    write.table(z, '"${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv', quote = FALSE, row.names = FALSE, col.names = TRUE, sep = ',')
    "`
    "${BIN_DIR}"/Rscript <(echo "${cmds}")
    echo "[Header]
    Date,"${RUNDATE}"
    Workflow,GenerateFASTQ
    Experiment Name,NSQ"${RUNNB}"

    [Data]" | sed 's/^[ \t]*//' > "${1}"
    
    ## -------- Check that all users detected in the samplesheet are already registered in `users.conf`. 
    USERS_CONFIG="${BASE_DIR}"/users.conf
    LISTED_USERS_IDS=`sed '1d' "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv | sed 's/.*,//' | sort | uniq`
    REGISTERED_USERS_IDS=`grep '\[' ${USERS_CONFIG} | sed 's,[][],,g'`
    unset UNREGISTERED_IDS
    for USER in $LISTED_USERS_IDS
    do
        if ( test `grep $USER <(grep '\[' ${USERS_CONFIG} | sed 's,[][],,g') | wc -l` -eq 0 ) ; then
            UNREGISTERED_IDS="${UNREGISTERED_IDS} ${USER}"
        fi
    done
    if ( test -n "${UNREGISTERED_IDS}" ) ; then
        msg="The following user(s) are not registered yet:\n\n${UNREGISTERED_IDS}\n\nPlease fill in ${USERS_CONFIG} before re-attempting to demultiplex."
        email_error "${msg}"
        echo -e "${msg}"
        exit 1
    fi

    ## -------- Check that all indices provided are listed in `indices.txt`
    INDICES="${BASE_DIR}"/indices.txt
    LISTED_INDICES=`sed '1d' "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv | sed 's/^[^,]*,[^,]*,,//' | sed 's/,.*//'`
    REGISTERED_INDICES=`sed 's,\s.*,,' ${INDICES}`
    unset UNREGISTERED_INDICES
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
        exit 1
    fi

    ## -------- Copy the fixed samplesheet to the output path
    cat "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv >> "${1}"
    rm -rf "${WORKING_DIR}"/rsgsheets/
}

## - Email notification
function email_start {
    SAMPLES=`cat "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' '`
    echo -e "Run ${RUN} started @ `date`\npath: "${SOURCE}"/\nsamples: ${SAMPLES}" | mailx \
        -s "[CLUSTER INFO] Submitted run ${RUN} to autobcl2fastq" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv \
        ${EMAIL} 
}
function email_error {
    echo -e "${1}" | mailx \
        -s "[CLUSTER INFO] ERROR run ${RUN} to autobcl2fastq" \
        ${EMAIL} 
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
SSH_HOSTNAME=sftpcampus
DESTINATION=/pasteur/gaia/projets/p02/Rsg_reads/nextseq_runs/ # Where the fastq are written at the end, should be `Rsg_reads/nextseq_runs` [HAS TO BE MOUNTED ON SFTPCAMPUS]
WORKING_DIR=/pasteur/appa/scratch/jaseriza/autobcl2fastq/ # Where the bcl files are processed into fastq, ideally a fast scratch
SBATCH_DIR=/opt/hpc/slurm/current/bin/ # Directory to sbatch bin
BIN_DIR=/pasteur/appa/homes/jaseriza/miniforge/bin/ # For xlsx2csv and Rscript dependencies
RCLONE_CONFIG=/pasteur/helix/projects/rsg_fast/jaseriza/autobcl2fastq/rclone.conf
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
        --bin_dir)
        BIN_DIR="${2}"
        shift 
        shift 
        ;;
        --rclone_conf)
        RCLONE_CONFIG="${2}"
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
        --samplesheet)
        samplesheet="${2}"
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

## - Check that Biomics run link has been manually provided/sent by email
if ( test -n "${URL}" ) ; then
    echo "Continuing with run URL manually provided: ${URL}"
else
    fn_log "Checking mailbox for Biomics e-mail"
    URL=`"${BASE_DIR}"/bin/check_emails.py`
    if ( test -n "${URL}" ) ; then
        echo "Run link found: ${URL}"
    else
        echo "No run link found. You can manually provide one with \`--url <URL>\`."
        exit 0
    fi
fi

## - Download run sample sheet from rsgteams
RUN=`basename ${URL} | sed 's,__.*,,'`
RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
SEQID=`echo "${RUN}" | sed "s,.*${RUNDATE}_,,g" | sed "s,_.*,,g"`
RUNNB=`echo "${RUN}" | sed "s,.*${SEQID}_,,g" | sed "s,_.*,,g"`
RUNHASH=`echo "${RUN}" | sed "s,.*${RUNNB}_,,g" | sed "s,_.*,,g"`
SOURCE="${WORKING_DIR}/runs/"
echo "${RUN}" > "${WORKING_DIR}"/PROCESSING
if ( test -n "${samplesheet}" ) ; then
    fn_log "Using the local samplesheet: ${samplesheet}"
    fix_local_samplesheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv
else
    fn_log "Downloading run ${RUNHASH} sample sheet from RSG Teams folder"
    fix_samplesheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv
fi
echo -e ""
cat "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNDATE}"_"${RUNNB}"_"${RUNHASH}".csv
echo -e ""

## - Download run raw data
fn_log "Downloading raw data from Biomics"
curl -L "${URL}" -o "${WORKING_DIR}/runs/`basename ${URL}`"
tar -xf "${WORKING_DIR}"/runs/`basename "${URL}"` --directory "${WORKING_DIR}"/runs/
rm "${WORKING_DIR}"/runs/`basename "${URL}"`

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

exit 0
