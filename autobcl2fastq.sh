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
SHEETS_DIR="${BASE_DIR}"/samplesheets
OLD_PROCESSED_RUNS="${BASE_DIR}"/RUNS_ACHIEVED_LATEST
NEW_PROCESSED_RUNS="${BASE_DIR}"/RUNS_ACHIEVED_NEW

## ------------------------------------------------------------------
## -------- LOAD REQUIRED DEPS --------------------------------------
## ------------------------------------------------------------------

module purge
module load bcl2fastq/2.20.0
module load graalvm/ce-java8-20.0.0
module load fastqc/0.11.9
module load bowtie2/2.1.0
# multiqc, from conda base env.
# fastq_screen, from conda base env.

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

## - Process each run independantly
function process_run {
    RUNDATE=`echo $RUN | sed 's,_.*,,g'`
    RUNNB=`echo $RUN | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
    RUNHASH=`echo $RUN | sed 's,.*_,,g'`
    RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"

    ## - Cp entire run folder to local (not ideal, but easiest for now...)
    rsync "${SSH_HOSTNAME}":/pasteur/gaia/projets/p01/nextseq/${RUN} ${BASE_DIR}/ --recursive
    mv "${BASE_DIR}/${RUN}" "${BASE_DIR}/${RUNID}"

    ## - Fix sample sheet
    sed 's/,,,,,,,//g' "${BASE_DIR}"/"${RUNID}"/SampleSheet.csv \
        | sed 's/\[\(.*\)\],/\[\1\]/' \
        | sed 's/^\([0-9]*\)\,/\1/g' \
        | sed 's/^//g' \
        | sed 's/^$//g' \
        | grep -v -P "^," > "${SHEETS_DIR}"/SampleSheet_"${RUNID}".csv

    ## - Run bcl2fastq
    mkdir -p "${BASE_DIR}"/fastq/"${RUNID}"/
    bcl2fastq \
        --no-lane-splitting \
        -R "${BASE_DIR}"/"${RUNID}"/ \
        -o "${BASE_DIR}"/fastq/"${RUNID}"/ \
        --sample-sheet "${SHEETS_DIR}"/SampleSheet_"${RUNID}".csv \
        --loading-threads 4 \
        --processing-threads 4 \
        --writing-threads 4
    cp "${SHEETS_DIR}"/SampleSheet_"${RUNID}".csv "${BASE_DIR}"/fastq/"${RUNID}"/SampleSheet_"${RUNID}".csv

    ## - Run FastQC for all the samples
    #Adaptors from https://www.outils.genomique.biologie.ens.fr/leburon/downloads/aozan-example/adapters.fasta
    mkdir -p "${BASE_DIR}"/fastqc/"${RUNID}"
    fastqc \
        --outdir "${BASE_DIR}"/fastqc/"${RUNID}" \
        --noextract \
        --threads 12 \
        --adapters "${BASE_DIR}"/adapters.txt \
        "${BASE_DIR}"/fastq/"${RUNID}"/*/*fastq.gz

    ## - Run fastq_screen for all the samples
    mkdir -p "${BASE_DIR}"/fastqscreen/"${RUNID}"
    fastq_screen \
        --outdir "${BASE_DIR}"/fastqscreen/"${RUNID}" \
        --conf "${BASE_DIR}"/fastq_screen.conf \
        --threads 12 \
        "${BASE_DIR}"/fastq/"${RUNID}"/*/*fastq.gz

    ## - Run MultiQC to aggregate results (bcl2fastq, fastqc, fastq_screen)
    mkdir -p "${BASE_DIR}"/multiqc/"${RUNID}"
    multiqc \
        --title "${RUNID}" \
        --outdir "${BASE_DIR}"/multiqc/"${RUNID}" \
        --verbose \
        --module bcl2fastq \
        --module fastq_screen \
        --module fastqc \
        "${BASE_DIR}"/fastq/"${RUNID}" \
        "${BASE_DIR}"/fastqc/"${RUNID}" \
        "${BASE_DIR}"/fastqscreen/"${RUNID}"

    ## - Copy fastq reads to Rsg_reads
    rsync "${BASE_DIR}"/fastq/"${RUNID}"/ "${SSH_HOSTNAME}":/pasteur/projets/policy02/Rsg_reads/run_${RUNID}/ --recursive

    ## - Copy reports to Rsg_reads/reports
    rsync "${BASE_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html "${SSH_HOSTNAME}":/pasteur/projets/policy02/Rsg_reads/run_${RUNID}/MultiQC_"${RUNID}".html

}

## - Email notifications
function email_start {
    RUNDATE=`echo ${1} | sed 's,_.*,,g'`
    RUNNB=`echo ${1} | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
    RUNHASH=`echo ${1} | sed 's,.*_,,g'`
    RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"
    scp "${SSH_HOSTNAME}":/pasteur/gaia/projets/p01/nextseq/${RUN}/SampleSheet.csv tmp
    SAMPLES=`cat tmp | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' '`
    echo "Run ${1} started @ `date`
run: ${1}
path: /pasteur/gaia/projets/p01/nextseq/
samples: ${SAMPLES}" | mail -s "Starting bcl2fast & QCs for run ${1}" ${EMAIL}
    rm tmp
}

function email_finish {
    RUNDATE=`echo ${1} | sed 's,_.*,,g'`
    RUNNB=`echo ${1} | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
    RUNHASH=`echo ${1} | sed 's,.*_,,g'`
    RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"
    echo "" | mail \
        -s "Finished bcl2fast & QCs for run ${1}" \
        -a "${SHEETS_DIR}"/SampleSheet_"${RUNID}".csv \
        -a "${BASE_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html \
        ${EMAIL}
}

## ------------------------------------------------------------------
## ------------------- CHECKS ---------------------------------------
## ------------------------------------------------------------------

## - Checking that no process is currently on going
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
    for RUN in `cat "${BASE_DIR}"/RUNS_TO_PROCESS`
    do
        touch "${BASE_DIR}"/PROCESSING
        RUNDATE=`echo $RUN | sed 's,_.*,,g'`
        RUNNB=`echo $RUN | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
        RUNHASH=`echo $RUN | sed 's,.*_,,g'`
        RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"
        email_start "${RUN}"
        process_run "${RUN}"
        email_finish "${RUN}"
        rm "${BASE_DIR}"/PROCESSING
        # rm "${BASE_DIR}"/"${RUNID}"
    done
fi

rm "${BASE_DIR}"/RUNS_TO_PROCESS
mv "${NEW_PROCESSED_RUNS}" "${OLD_PROCESSED_RUNS}"
