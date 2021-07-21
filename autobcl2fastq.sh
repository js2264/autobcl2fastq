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
SSH_HOSTNAME=sftpcampus
EMAIL=${USER}@pasteur.fr
SBATCH_DIR=/pasteur/sonic/hpc/slurm/maestro/slurm/bin
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

## - Check that sample sheet exists for on going run
function check_sample_sheet { 
    if ssh "${SSH_HOSTNAME}" "test -e /pasteur/gaia/projets/p01/nextseq/${1}/SampleSheet.csv"; then
        exit 0
    else
        echo 1
    fi
}

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

## - Checking that no process is currently on going, immediately abort otherwise
if test -f "${BASE_DIR}"/PROCESSING ; then
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
rm "${NEW_PROCESSED_RUNS}"

## ------------------------------------------------------------------
## ------------------- PROCESSING NEW RUN(S) ------------------------
## ------------------------------------------------------------------

if (test `wc -l "${BASE_DIR}"/RUNS_TO_PROCESS | sed 's, .*,,'` -eq 0) ; then
    echo "No runs to process. Exiting now."
    exit 0
else 

    ## - Only process a single run, the first one in line
    RUN=`cat "${BASE_DIR}"/RUNS_TO_PROCESS | head -n 1`
    #RUN=210716_NS500150_0646_AHG2W5BGXJ

    ## - Check that a sample sheet exists for this run, otherwise go to next run
    while (test `check_sample_sheet ${RUN}`)
    do
        echo "Missing sample sheet for ${RUN}"
        sed -i "s,${RUN},," "${BASE_DIR}"/RUNS_TO_PROCESS
        sed -i '/^$/d' "${BASE_DIR}"/RUNS_TO_PROCESS
        RUN=`cat "${BASE_DIR}"/RUNS_TO_PROCESS | head -n 1`
        if (test "${RUN}" == '') ; then 
            echo "No new samples with sample sheet can be processed. Finishing now"
            exit 0
        fi
    done

    ## - Process run
    ## |--- Sync files from nextseq repo
    ## |--- Fix sample sheet
    ## |--- Run bcl2fastq, fastqc, fastq_screen, multiQC as a SLURM job
    ## |--- Copy fastq reads to Rsg_reads
    ## |--- Copy reports to Rsg_reads/reports
    ## |--- Enable Read/Write for all files
    
    echo "Processing run ${RUN}"
    "${SBATCH_DIR}"/sbatch \
        -J "${RUN}" \
        -D "${BASE_DIR}" \
        -o /pasteur/sonic/homes/jaseriza/autobcl2fast_"${RUN}".out -e /pasteur/sonic/homes/jaseriza/autobcl2fast_"${RUN}".err \
        --export=SSH_HOSTNAME="${SSH_HOSTNAME}",BASE_DIR="${BASE_DIR}",RUN="${RUN}",EMAIL="${EMAIL}" \
        "${BASE_DIR}"/bin/process_run.sh 

fi
