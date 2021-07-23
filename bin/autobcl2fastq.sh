#!/bin/bash

VERSION=0.2.0

## ------------------------------------------------------------------
## ------------------- USAGE ----------------------------------------
## ------------------------------------------------------------------

function usage {
    echo "This script should be launched as a cron job, every hour or so. To do so, run the following commands"
    echo "Written by J. Serizay"
    echo " "
    echo "crontab -l > mycron"
    echo "echo '*/10 * * * * sbatch ~/rsg_fast/jaseriza/autobcl2fastq/autobcl2fastq.sh' >> mycron"
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
EMAIL=${USER}@pasteur.fr
SSH_HOSTNAME=sftpcampus
SOURCE=/pasteur/projets/policy01/nextseq # Where the bcl are hosted, should be `nextseq` project
DESTINATION=/pasteur/projets/policy02/Rsg_reads/nextseq_runs # Where the fastq are written at the end, should be `Rsg_reads`
# DESTINATION=/pasteur/sonic/scratch/users/jaseriza
BASE_DIR=/pasteur/zeus/projets/p02/rsg_fast/jaseriza/autobcl2fastq # Where the script is hosted, should be in `rsg_fast`
WORKING_DIR=/pasteur/appa/scratch/public/jaseriza/autobcl2fastq # Where the bcl files are processed into fastq, ideally a fast scratch
SBATCH_DIR=/pasteur/sonic/hpc/slurm/maestro/slurm/bin # Directory to sbatch bin
#RUN=200505_NS500150_0533_AH7HV7AFX2

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

## - Get list of all runs
function fetch_runs {
    ssh "${SSH_HOSTNAME}" ls /pasteur/gaia/projets/p01/nextseq/*/RTAComplete.txt \
        | sed 's,/RTAComplete.txt,,' \
        | sed 's,.*/,,' 
}

## - Check if new runs were created
function compare_runs { 
    if ( test `wc -l "${1}" | sed 's, .*,,'` -lt `wc -l "${2}" | sed 's, .*,,'` ) ; then
        NEW_RUN=`grep -v -f ${1} ${2}`
        echo "${NEW_RUN}"
    fi
}

## - Check that sample sheet exists for on going run
function check_sample_sheet { 
    if ssh "${SSH_HOSTNAME}" "test -e /pasteur/gaia/projets/p01/nextseq/${1}/SampleSheet.csv"; then
        exit 0
    else
        echo 1
    fi
}

## - Email notification
function email_start {
    rsync "${SSH_HOSTNAME}":"${SOURCE}"/${RUN}/SampleSheet.csv tmp
    samples=`cat tmp | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' '`
    echo -e "Run ${RUN} started @ `date`\npath: "${SOURCE}"/\nsamples: ${samples}" | \
        mailx -s "Submitted run ${RUN} to autobcl2fastq" ${EMAIL}
    rm tmp
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
if ( test ! -f "${WORKING_DIR}"/PROCESSED_RUNS ) ; then
    echo "No previous runs are registered. A file named "${WORKING_DIR}"/PROCESSED_RUNS should exist. Aborting now."
    exit 0
fi

## - Checking for new runs
fetch_runs > "${WORKING_DIR}"/ALL_RUNS
compare_runs "${WORKING_DIR}"/PROCESSED_RUNS "${WORKING_DIR}"/ALL_RUNS > "${WORKING_DIR}"/RUNS_TO_PROCESS
rm "${WORKING_DIR}"/ALL_RUNS

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN(S) ------------------------
## ------------------------------------------------------------------

if ( test `wc -l "${WORKING_DIR}"/RUNS_TO_PROCESS | sed 's, .*,,'` -eq 0 ) ; then
    echo "No runs to process. Exiting now."
    exit 0
else 

    ## - Only process a single run, the first one in line
    RUN=`cat "${WORKING_DIR}"/RUNS_TO_PROCESS | head -n 1`

    ## - Check that a sample sheet exists for this run, otherwise go to next run
    while ( test `check_sample_sheet ${RUN}` )
    do
        echo "Missing sample sheet for ${RUN}"
        sed -i "s,${RUN},," "${WORKING_DIR}"/RUNS_TO_PROCESS
        sed -i '/^$/d' "${WORKING_DIR}"/RUNS_TO_PROCESS
        RUN=`cat "${WORKING_DIR}"/RUNS_TO_PROCESS | head -n 1`
        if ( test "${RUN}" == '' ) ; then 
            echo "No new samples with sample sheet can be processed. Finishing now"
            rm "${WORKING_DIR}"/RUNS_TO_PROCESS
            exit 0
        fi
    done
    rm "${WORKING_DIR}"/RUNS_TO_PROCESS

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
    
fi
