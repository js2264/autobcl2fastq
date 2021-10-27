#!/bin/bash

VERSION=0.2.0
SCRIPTPATH="$( cd -- "$(dirname $(dirname "$0"))" >/dev/null 2>&1 ; pwd -P )" # absolute script path, handling symlinks, spaces and hyphens

## ------------------------------------------------------------------
## ------------------- USAGE ----------------------------------------
## ------------------------------------------------------------------

function usage {
    echo "This script should be launched as a cron job, every 10' or so. To do so, run the following commands"
    echo "Written by J. Serizay"
    echo " "
    echo "crontab -l > mycron"
    echo "echo '*/10 * * * * sbatch \"${SCRIPTPATH}/$0\"' >> mycron"
    echo "crontab mycron"
    echo "rm mycron"
}

for arg in "$@"
do
    case $arg in
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
## -------- ENV. VARIABLES ------------------------------------------
## ------------------------------------------------------------------

USER=jaseriza
EMAIL="${USER}"@pasteur.fr
SSH_HOSTNAME=sftpcampus
GROUP=Rsg #ownership group for the sample sheets
SOURCE=/pasteur/projets/policy01/nextseq # Where the bcl are hosted, should be `nextseq` project
DESTINATION=/pasteur/projets/policy02/Rsg_reads/nextseq_runs # Where the fastq are written at the end, should be `Rsg_reads`
BASE_DIR="${SCRIPTPATH}" # Where the script is hosted, should be in `rsg_fast`
WORKING_DIR=/pasteur/appa/scratch/public/jaseriza/autobcl2fastq # Where the bcl files are processed into fastq, ideally a fast scratch
SBATCH_DIR=/pasteur/sonic/hpc/slurm/maestro/slurm/bin # Directory to sbatch bin

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

## - Get list of Koszul runs from JS GDrive folder (shared with the lab). This requires a custom GDrive set up for `rclone`
function fetch_samplesheets {
    ls "${WORKING_DIR}"/samplesheets/ > "${1}"
    rclone lsf GDriveJS:rsg/ | grep rsgsheet | grep -v xxx > tmp
    grep -v -f "${1}" tmp > "${2}"
    rm tmp
}

## - Email notification
function email_start {
    echo -e "Run ${RUN} started @ `date`\npath: "${SOURCE}"/" | \
        mailx -s "Submitted run ${RUN} to autobcl2fastq" ${EMAIL}
}

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

## - Checking that no process is currently on going, immediately abort otherwise
if ( test -f "${WORKING_DIR}"/PROCESSING || test `${SBATCH_DIR}/sacct --format=Jobname%35,state | grep 'NS500150' | grep PENDING | wc -l` -gt 0 ) ; then
    echo "Samples currently being processed. Aborting now."
    exit 0
fi

## - Checking that previous processes are registered (at least an empty file exists)
if ( test ! -f "${WORKING_DIR}"/PROCESSED_SAMPLESHEETS ) ; then
    echo "No previous runs are registered. A file named "${WORKING_DIR}"/PROCESSED_SAMPLESHEETS should exist. Aborting now."
    exit 0
fi

## - Checking for new runs
fetch_samplesheets "${WORKING_DIR}"/PROCESSED_SAMPLESHEETS "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS

## - Checking that there is a run to process
if ( test `wc -l "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | sed 's, .*,,'` -eq 0 ) ; then
    echo "No runs to process. Exiting now."
    exit 0
fi

## - Selecting only the first run from the list of samplesheets to process
RUNNB=`cat "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | head -n 1 | sed 's,rsgsheet_NSQ,,' | sed 's,.xlsx,,'`
RUN=`ssh "${SSH_HOSTNAME}" ls /pasteur/gaia/projets/p01/nextseq/ | grep -P  "_${RUNNB}_"`

## - Checking that the run has actually finished
if ( ssh "${SSH_HOSTNAME}" test ! -f /pasteur/gaia/projets/p01/nextseq/"${RUN}"/RTAComplete.txt ) ; then
    echo "Run ${RUN} is not finished. Aborting for now."
    exit 0
fi

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN ---------------------------
## ------------------------------------------------------------------

## - Start processing
echo "${RUN}" > "${WORKING_DIR}"/PROCESSING

## - Notify start of new run being processed
email_start

## - Process run
## |--- Sync files from nextseq repo
## |--- Fix sample sheet
## |--- Run bcl2fastq, fastqc, fastq_screen, multiQC 
## |--- Copy fastq reads to Rsg_reads
## |--- Copy reports to Rsg_reads/reports
## |--- Enable Read/Write for all files

echo "Processing run ${RUN}"
"${SBATCH_DIR}"/sbatch \
    -J "${RUN}" \
    -o "${WORKING_DIR}"/autobcl2fast_"${RUN}".out \
    -e "${WORKING_DIR}"/autobcl2fast_"${RUN}".err \
    --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",WORKING_DIR="${WORKING_DIR}",RUN="${RUN}",EMAIL="${EMAIL}",SOURCE="${SOURCE}",DESTINATION="${DESTINATION}" \
    "${BASE_DIR}"/bin/process_run.sh 
