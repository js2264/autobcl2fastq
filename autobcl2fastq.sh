#!/bin/bash

#SBATCH --cpus-per-task 12
#SBATCH --mem 48G
#SBATCH -o autobcl2fast.out -e autobcl2fast.err

VERSION=0.1.0

## ------------------------------------------------------------------
## ------------------- USAGE ----------------------------------------
## ------------------------------------------------------------------

function usage {
    echo "This script should be launched as a cron job, every hour or so. To do so, run the following commands"
    echo "Written by J. Serizay"
    echo " "
    echo "crontab -l > mycron"
    echo "30 * * * * sbatch ~/rsg_fast/jaseriza/autobcl2fastq/autobcl2fastq.sh >> mycron"
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
SSH_HOSTNAME=sftpcampus
EMAIL=${USER}@pasteur.fr
BASE_DIR=/pasteur/zeus/projets/p02/rsg_fast/jaseriza/autobcl2fastq
OLD_PROCESSED_RUNS="${BASE_DIR}"/RUNS_ACHIEVED
NEW_PROCESSED_RUNS="${BASE_DIR}"/RUNS_ACHIEVED_NEW

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
    if (test `wc -l "${1}" | sed 's, .*,,'` -lt `wc -l "${2}" | sed 's, .*,,'`) ; then
        NEW_RUN=`grep -v -f ${1} ${2}`
        echo "${NEW_RUN}"
    fi
}

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

## - Checking that no process is currently on going, immediately abort otherwise
if test -f "${BASE_DIR}"/RUNS_TO_PROCESS || test -f "${BASE_DIR}"/PROCESSING ; then
    echo "Samples currently being processed. Aborting now."
    exit 0
fi

## - Checking that previous processes are registered (at least an empty file exists)
if test ! -f "${OLD_PROCESSED_RUNS}" ; then
    echo "No previous runs are registered. A file named ${OLD_PROCESSED_RUNS} should exist. Aborting now."
    exit 0
fi

## - Checking for new runs
fetch_runs > "${NEW_PROCESSED_RUNS}"
compare_runs "${OLD_PROCESSED_RUNS}" "${NEW_PROCESSED_RUNS}" > "${BASE_DIR}"/RUNS_TO_PROCESS

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN(S) ------------------------
## ------------------------------------------------------------------

if (test `wc -l "${BASE_DIR}"/RUNS_TO_PROCESS | sed 's, .*,,'` -eq 0) ; then
    echo "No runs to process. Exiting now."
    exit 0
else 
    cat "${BASE_DIR}"/RUNS_TO_PROCESS
    for RUN in `cat "${BASE_DIR}"/RUNS_TO_PROCESS`
    do

        ## - Process run
        ## |--- Sync files from nextseq repo
        ## |--- Fix sample sheet
        ## |--- Run bcl2fastq, fastqc, fastq_screen, multiQC as a SLURM job
        ## |--- Copy fastq reads to Rsg_reads
        ## |--- Copy reports to Rsg_reads/reports
        ## |--- Enable Read/Write for all files
        
        sbatch \
            -D "${BASE_DIR}" \
            -o /pasteur/sonic/homes/jaseriza/autobcl2fast_"${RUN}".out -e /pasteur/sonic/homes/jaseriza/autobcl2fast_"${RUN}".err \
            --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",RUN="${RUN}" \
            "${BASE_DIR}"/bin/process_run.sh 

    done
fi

rm "${NEW_PROCESSED_RUNS}"
rm "${BASE_DIR}"/RUNS_TO_PROCESS
