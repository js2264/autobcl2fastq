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
BIN_DIR=/pasteur/sonic/homes/jaseriza/bin/miniconda3/bin/ # For xlsx2csv and Rscript dependencies

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

## - Get list of Koszul runs from JS GDrive folder (shared with the lab). This requires a custom GDrive set up for `rclone`
function fetch_samplesheets {
    ls "${WORKING_DIR}"/samplesheets/ | sed 's,.*_NSQ,,' | sed 's,.csv,,' > tmp0
    rclone lsf GDriveJS:rsg/ | grep rsgsheet | grep -v xxx > tmp
    grep -v -f tmp0 tmp > "${1}"
    rm tmp*
}

## - Fill out a Illumina sample sheet using info from an Rsg sample sheet
function fix_samplesheet {
    rclone copy GDriveJS:/rsg/rsgsheet_NSQ"${RUNNB}".xlsx "${WORKING_DIR}"/rsgsheets/
    cp "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}".xlsx "${WORKING_DIR}"/samplesheets/rsgsheet_NSQ"${RUNNB}".xlsx
    "${BIN_DIR}"/xlsx2csv "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}".xlsx | cut -f 1-8 -d, | grep -v ^, | grep -v ^[0-9]*,, > "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}".csv
    cmds=`echo -e "
    x <- read.csv('"${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}".csv') ;
    y <- read.csv('${BASE_DIR}/indices.txt', header = TRUE, sep = '\\\\\t') ; 
    x <- merge(x, y, by = 'barcode_well') ;
    z <- data.frame(Sample_ID = x\\$sample_id, Sample_Name = x\\$sample_id, Sample_Plate = '', Sample_Well = x\\$barcode_well, I7_Index_ID = '', index = x\\$i7_sequence, I5_Index_ID = '', index2 = x\\$i5_sequence, Sample_Project = gsub('[0-9].*', '', x\\$sample_id)) ;
    write.table(z, '"${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}"_fixed.csv', quote = FALSE, row.names = FALSE, col.names = TRUE, sep = ',')
    "`
    "${BIN_DIR}"/Rscript <(echo "${cmds}")
    cp "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}".xlsx "${WORKING_DIR}"/samplesheets/
    echo "[Header]
    Date,"${RUNDATE}"
    Workflow,GenerateFASTQ
    Experiment Name,NSQ"${RUNNB}"

    [Data]" | sed 's/^[ \t]*//' > "${1}"
    cat "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${RUNNB}"_fixed.csv >> "${1}"
    rm -rf "${WORKING_DIR}"/rsgsheets/
}

## - Email notification
function email_start {
    echo "Run ${RUN} started @ `date`\npath: "${SOURCE}"/" | mailx \
        -s "Submitted run ${RUN} to autobcl2fastq" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv \
        ${EMAIL} 
}

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

## - Checking that no process is currently on going, immediately abort otherwise
if ( test -f "${WORKING_DIR}"/PROCESSING || test `${SBATCH_DIR}/sacct --format=Jobname%35,state | grep 'NS500150' | grep PENDING | wc -l` -gt 0 ) ; then
    echo "Samples currently being processed. Aborting now."
    exit 0
fi

## - Checking for new runs
fetch_samplesheets "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS

## - Checking that there is a run to process
if ( test `wc -l "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | sed 's, .*,,'` -eq 0 ) ; then
    echo "No runs to process. Exiting now."
    exit 0
fi

## - Selecting only the first run from the list of samplesheets to process
RUNNB=`cat "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | head -n 1 | sed 's,rsgsheet_NSQ,,' | sed 's,.xlsx,,'`
RUN=`ssh "${SSH_HOSTNAME}" ls /pasteur/gaia/projets/p01/nextseq/ | grep -P  "_${RUNNB}_"`
RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`

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
rm "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS

## - Download run sample sheet from GDrive:rsg/
fix_samplesheet "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv

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
    -o "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".out \
    -e "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".err \
    --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",WORKING_DIR="${WORKING_DIR}",RUN="${RUN}",EMAIL="${EMAIL}",SOURCE="${SOURCE}",DESTINATION="${DESTINATION}" \
    "${BASE_DIR}"/bin/process_run.sh 
