#!/bin/bash

VERSION=0.4.0
SCRIPTPATH="$( cd -- "$(dirname $(dirname "$0"))" >/dev/null 2>&1 ; pwd -P )" # absolute script path, handling symlinks, spaces and hyphens
RUNHASH=""

## ------------------------------------------------------------------
## ------------------- HELPER FUNCTIONS -----------------------------
## ------------------------------------------------------------------

## - Usage help
function usage {
    echo -e "Written by J. Serizay"
    echo -e ""
    echo -e "For automated bcl2fastq processing: "
    echo -e "----------------------------------- "
    echo -e "This script should be launched as a cron job, every 10' or so. To do so, run the following commands"
    echo -e ""
    echo -e "\tcrontab -l > mycron"
    echo -e "\techo '*/10 * * * * sbatch $0' >> mycron"
    echo -e "\tcrontab mycron"
    echo -e ""
    echo -e ""
    echo -e "For manual processing mode: "
    echo -e "--------------------------- "
    echo -e "EXPERIMENTAL - Only use this if you know what you are doing"
    echo -e "This requires several dependencies, a SSH config file with a sftpcampus access set up, a rclone config file for access to RSG Teams files, ..."
    echo -e ""
    echo -e "Usage: $0 [ OPTIONAL ARGUMENTS ]"
    echo -e ""
    echo -e "   --email <EMAIL>                  | Default: jaseriza@pasteur.fr"
    echo -e "                                        Email address for notifications."
    echo -e ""
    echo -e "   --ssh_hostname <SSH_HOSTNAME>    | Default: sftpcampus"
    echo -e "                                        Alias for access to sftpcampus set up in your ~/.ssh/config."
    echo -e ""
    echo -e "   --nextseq_dir <SOURCE>           | Default: /pasteur/projets/policy01/nextseq"
    echo -e "                                        Directory where the run raw files are stored (available from sftpcampus)."
    echo -e ""
    echo -e "   --reads_dir <DESTINATION>        | Default: /pasteur/projets/policy02/Rsg_reads/nextseq_runs"
    echo -e "                                        Directory where the reads are going to be copied (available from sftpcampus)."
    echo -e ""
    echo -e "   --working_dir <WORKING_DIR>      | Default: /pasteur/appa/scratch/public/jaseriza/autobcl2fastq"
    echo -e "                                        Directory where demultiplexing takes place (available from maestro)."
    echo -e "                                        Samplesheets are going to be formatted and backed up here."
    echo -e ""
    echo -e "   --sbatch_dir <SBATCH_DIR>        | Default: /pasteur/sonic/hpc/slurm/maestro/slurm/bin"
    echo -e "                                        Directory for sbatch dependency."
    echo -e ""
    echo -e "   --bin_dir <BIN_DIR>              | Default: /pasteur/sonic/homes/jaseriza/bin/miniconda3/bin/"
    echo -e "                                        Directory for xlsx2csv and Rscript dependencies."
    echo -e ""
    echo -e "   --rclone_conf <RCLONE_CONFIG>    | Default: /pasteur/zeus/projets/p02/rsg_fast/jaseriza/autobcl2fastq/rclone.conf"
    echo -e "                                        This file contains credentials to authenticate to RSG Teams repository."
    echo -e ""
    echo -e "   --run <ChipID>                 | Default: empty."
    echo -e "                                        Specify one to re-process a specific run."
    echo -e "                                        The matching run sheet has to exist in RSG Teams."
    echo -e ""
    echo -e ""
}

## - Compare the list of run sheets from RSG Teams folder (shared with the lab) to the list of samplesheets already processed. 
# This requires a custom rsgteams access point set up for `rclone`.
function fetch_samplesheets {
    grep -v -f <(ls "${WORKING_DIR}"/samplesheets/ | sed 's,.*_,,' | sed 's,.csv,,') <(rclone lsf rsgteams:'Experimentalist group/sequencing_runs/' --config "${RCLONE_CONFIG}" | grep rsgsheet | grep -v xxx) \
    | sed 's,rsgsheet_,,' | sed 's,.xlsx,,' > "${1}"
}

## - Create an Illumina sample sheet using info from an Rsg sample sheet
function fix_samplesheet {
    rclone copy rsgteams:"Experimentalist group/sequencing_runs/rsgsheet_${RUNHASH}.xlsx" "${WORKING_DIR}"/rsgsheets/ --config "${RCLONE_CONFIG}"
    "${BIN_DIR}"/xlsx2csv "${WORKING_DIR}"/rsgsheets/rsgsheet_${RUNHASH}.xlsx | cut -f 1-8 -d, | grep -v ^, | grep -v ^[0-9]*,, > "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}".csv
    cmds=`echo -e "
    x <- read.csv('"${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}".csv') ;
    y <- read.csv('${BASE_DIR}/indices.txt', header = TRUE, sep = '\\\\\t') ; 
    x <- merge(x, y, by = 'barcode_well') ;
    z <- data.frame(Sample_ID = x\\$sample_id, Sample_Name = x\\$sample_id, Sample_Plate = '', Sample_Well = x\\$barcode_well, I7_Index_ID = '', index = x\\$i7_sequence, I5_Index_ID = '', index2 = x\\$i5_sequence, Sample_Project = gsub('[0-9].*', '', x\\$sample_id)) ;
    write.table(z, '"${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv', quote = FALSE, row.names = FALSE, col.names = TRUE, sep = ',')
    "`
    "${BIN_DIR}"/Rscript <(echo "${cmds}")
    echo "[Header]
    Date,"${RUNDATE}"
    Workflow,GenerateFASTQ
    Experiment Name,NSQ"${RUNNB}"

    [Data]" | sed 's/^[ \t]*//' > "${1}"
    cat "${WORKING_DIR}"/rsgsheets/rsgsheet_"${RUNHASH}"_fixed.csv >> "${1}"
    rm -rf "${WORKING_DIR}"/rsgsheets/
}

## - Email notification
function email_start {
    SAMPLES=`cat "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' '`
    echo -e "Run ${RUN} started @ `date`\npath: "${SOURCE}"/\nsamples: ${SAMPLES}" | mailx \
        -s "[CLUSTER INFO] Submitted run ${RUN} to autobcl2fastq" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv \
        ${EMAIL} 
}

## - Logging function
function fn_log {
    echo -e "`date "+%y-%m-%d %H:%M:%S"` [INFO] $@"
}

## ------------------------------------------------------------------
## -------- PARSING ARGUMENTS ---------------------------------------
## ------------------------------------------------------------------

# Default values of arguments

EMAIL=jaseriza@pasteur.fr
SSH_HOSTNAME=sftpcampus
SOURCE=/pasteur/projets/policy01/nextseq # Where the bcl are hosted, should be `nextseq` project
DESTINATION=/pasteur/projets/policy02/Rsg_reads/nextseq_runs # Where the fastq are written at the end, should be `Rsg_reads`
WORKING_DIR=/pasteur/appa/scratch/public/jaseriza/autobcl2fastq # Where the bcl files are processed into fastq, ideally a fast scratch
SBATCH_DIR=/pasteur/sonic/hpc/slurm/maestro/slurm/bin # Directory to sbatch bin
BIN_DIR=/pasteur/sonic/homes/jaseriza/bin/miniconda3/bin # For xlsx2csv and Rscript dependencies
RCLONE_CONFIG=/pasteur/zeus/projets/p02/rsg_fast/jaseriza/autobcl2fastq/rclone.conf
BASE_DIR="${SCRIPTPATH}" # Where the script is hosted, should be in `/pasteur/sonic/homes/jaseriza/rsg_fast/jaseriza/autobcl2fastq/`

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
        --nextseq_dir)
        SOURCE="${2}"
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
        --run)
        RUNHASH="${2}"
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
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

fn_log "cmd: ${0}"

## - Checking that no process is currently on going, immediately abort otherwise
fn_log "Checking that no process is currently on going"
if ( test -f "${WORKING_DIR}"/PROCESSING || test `${SBATCH_DIR}/sacct --format=Jobname%35,state | grep 'NS500150' | grep PENDING | wc -l` -gt 0 ) ; then
    echo "Samples currently being processed. Aborting now."
    exit 0
fi
echo "${RUN}" > "${WORKING_DIR}"/PROCESSING

## - If a run ID is manually set...
if ( test -n "${RUNHASH}" ) ; then

    ## - Check that its samplesheet exists in Teams
    if ( test `rclone lsf rsgteams:'Experimentalist group/sequencing_runs/' --config "${RCLONE_CONFIG}" | grep rsgsheet | grep -v xxx | grep "${RUNHASH}" | wc -l` -eq 0 ) ; then
        echo "Samplesheet for run "${RUNHASH}" not found in Teams. Aborting now."
        rm "${WORKING_DIR}"/PROCESSING
        exit 0
    fi
    fn_log "Manually processing ${RUNHASH}"

## - If no run ID is manually set...
else

    ## - Checking for new runs
    fn_log "Fetching samplesheets from RSG Teams folder"
    fetch_samplesheets "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS

    ## - Checking that there is a run to process
    fn_log "Checking for new runs"
    if ( test `wc -l "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | sed 's, .*,,'` -eq 0 ) ; then
        echo "No new runs to process. Exiting now."
        rm "${WORKING_DIR}"/PROCESSING
        exit 0
    fi

    ## - Selecting only the first run from the list of samplesheets to process
    RUNHASH=`cat "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS | head -n 1`
    rm "${WORKING_DIR}"/SAMPLESHEETS_TO_PROCESS
    fn_log "New run found: ${RUNHASH}"

fi 

## - Check that run exists in source directory
fn_log "Checking that run exists in ${SOURCE}"
RUN=`ssh "${SSH_HOSTNAME}" ls "${SOURCE}"/ | grep -P "_${RUNHASH}"`
if ( test -n "${RUN}" ) ; then
    RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
    SEQID=`echo "${RUN}" | sed "s,.*${RUNDATE}_,,g" | sed "s,_.*,,g"`
    RUNNB=`echo "${RUN}" | sed "s,.*${SEQID}_,,g" | sed "s,_.*,,g"`
    fn_log "Run found: Run # ${RUNNB} / Run date ${RUNDATE} / Sequencer ${SEQID} / Chip ID ${RUNHASH}"
    fn_log "Manually processing ${RUNHASH}"
else
    fn_log "Run not found in ${SOURCE}. Aborting now."
    echo "[CLUSTER INFO] Failed to find run ${RUNHASH} in ${SOURCE}" | mailx \
        -s "[CLUSTER INFO] Failure" \
        ${EMAIL}
    rm "${WORKING_DIR}"/PROCESSING
    exit 0
fi

## - Checking that the run has actually finished
fn_log "Checking if the run ${RUNHASH} has finished"
if ( ssh "${SSH_HOSTNAME}" test ! -f "${SOURCE}"/"${RUN}"/RTAComplete.txt ) ; then
    echo "Run ${RUN} is not finished. Aborting for now."
    rm "${WORKING_DIR}"/PROCESSING
    exit 0
fi

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN ---------------------------
## ------------------------------------------------------------------

## - Download run sample sheet from rsgteams
fn_log "Downloading run ${RUNHASH} sample sheet from RSG Teams folder"
fix_samplesheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv

## - Copy sample sheet to `nextseq` project
scp "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv "${SSH_HOSTNAME}":"${SOURCE}"/"${RUN}"/
ssh "${SSH_HOSTNAME}" chmod 660 "${SOURCE}"/"${RUN}"/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv

## - Notify start of new run being processed
email_start

## - Process run
## |--- Sync files from nextseq repo
## |--- Fix sample sheet
## |--- Run bcl2fastq, fastqc, fastq_screen, multiQC 
## |--- Copy fastq reads to Rsg_reads
## |--- Copy reports to Rsg_reads/reports
## |--- Enable Read/Write for all files

fn_log "Processing run ${RUN}"
"${SBATCH_DIR}"/sbatch \
    -J "${RUN}" \
    -o "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".out \
    -e "${WORKING_DIR}"/batch_logs/autobcl2fast_"${RUN}".err \
    --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",WORKING_DIR="${WORKING_DIR}",RUN="${RUN}",EMAIL="${EMAIL}",SOURCE="${SOURCE}",DESTINATION="${DESTINATION}" \
    "${BASE_DIR}"/bin/process_run.sh 
