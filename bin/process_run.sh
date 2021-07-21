#!/bin/bash

#SBATCH --qos fast
#SBATCH --cpus-per-task 20
#SBATCH --mem 48G

## ------------------------------------------------------------------
## -------- DEPENDENCIES --------------------------------------------
## ------------------------------------------------------------------

module purge
module load bcl2fastq/2.20.0
module load graalvm/ce-java8-20.0.0
module load fastqc/0.11.9
module load bowtie2/2.1.0
# multiqc, from conda base env.
# fastq_screen, from conda base env.

## ------------------------------------------------------------------
## -------- ENV. VARIABLES ------------------------------------------
## ------------------------------------------------------------------

RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
RUNNB=`echo "${RUN}" | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
RUNHASH=`echo "${RUN}" | sed 's,.*_,,g'`
RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

function email_start {
    rsync "${SSH_HOSTNAME}":"${SOURCE}"/${1}/SampleSheet.csv tmp
    samples=`cat tmp | sed -n '/Sample_ID/,$p' | sed 's/^//g' | sed 's/^$//g' | grep -v '^,' | grep -v -P "^," | sed '1d' | cut -f1 -d, | tr '\n' ' '`
    echo "Run ${1} started @ `date`
run: ${1}
path: "${SOURCE}"/
samples: ${samples}" | mail -s "Submitted run ${1} to autobcl2fastq" ${EMAIL}
    rm tmp
}

function email_finish {
    echo "" | mail \
        -s "Finished bcl2fast & QCs for run ${1}" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_"${1}".csv \
        -a "${WORKING_DIR}"/multiqc/"${1}"/"${1}"_multiqc_report.html \
        ${EMAIL}
}

function fn_log {
    echo -e "`date "+%y-%m-%d %H:%M:%S"` [INFO] $@"
}

## ------------------------------------------------------------------
## -------- PROCESSING ----------------------------------------------
## ------------------------------------------------------------------

## - Notify start of new run being processed
email_start "${RUN}"

## - Cp entire run folder from nextseq repo to maestro ($WORKING_DIR)
fn_log "Fetching seq. run"
mkdir -p "${WORKING_DIR}"/runs
rsync "${SSH_HOSTNAME}":"${SOURCE}"/"${RUN}"/ "${WORKING_DIR}"/runs/"${RUNID}"/ --recursive

## - Fix sample sheet
fn_log "Fixing sample sheet"
mkdir -p "${WORKING_DIR}"/samplesheets
sed 's/,,,,,,,//g' "${WORKING_DIR}"/runs/"${RUNID}"/SampleSheet.csv \
    | sed 's/\[\(.*\)\],/\[\1\]/' \
    | sed 's/^\([0-9]*\)\,/\1/g' \
    | sed 's/^//g' \
    | sed 's/^$//g' \
    | grep -v -P "^," > "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv

## - Run bcl2fastq
fn_log "Running bcl2fastq"
mkdir -p "${WORKING_DIR}"/fastq/"${RUNID}"/
bcl2fastq \
    --no-lane-splitting \
    -R "${WORKING_DIR}"/runs/"${RUNID}"/ \
    -o "${WORKING_DIR}"/fastq/"${RUNID}"/ \
    --sample-sheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv \
    --loading-threads 6 \
    --processing-threads 6 \
    --writing-threads 6
cp "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv "${WORKING_DIR}"/fastq/"${RUNID}"/SampleSheet_"${RUNID}".csv

## - Run FastQC for all the samples
#Adaptors adapted from https://www.outils.genomique.biologie.ens.fr/leburon/downloads/aozan-example/adapters.fasta
fn_log "Running FastQC"
mkdir -p "${WORKING_DIR}"/fastqc/"${RUNID}"
fastqc \
    --outdir "${WORKING_DIR}"/fastqc/"${RUNID}" \
    --noextract \
    --threads 12 \
    --adapters "${BASE_DIR}"/adapters.txt \
    "${WORKING_DIR}"/fastq/"${RUNID}"/*/*fastq.gz 1>&2

## - Run fastq_screen for all the samples
fn_log "Running fastq_screen"
mkdir -p "${WORKING_DIR}"/fastqscreen/"${RUNID}"
fastq_screen \
    --outdir "${WORKING_DIR}"/fastqscreen/"${RUNID}" \
    --conf "${BASE_DIR}"/fastq_screen.conf \
    --threads 12 \
    "${WORKING_DIR}"/fastq/"${RUNID}"/*/*fastq.gz

## - Run MultiQC to aggregate results (bcl2fastq, fastqc, fastq_screen)
fn_log "Running multiqc"
mkdir -p "${WORKING_DIR}"/multiqc/"${RUNID}"
multiqc \
    --title "${RUNID}" \
    --outdir "${WORKING_DIR}"/multiqc/"${RUNID}" \
    --verbose \
    --module bcl2fastq \
    --module fastq_screen \
    --module fastqc \
    "${WORKING_DIR}"/fastq/"${RUNID}" \
    "${WORKING_DIR}"/fastqc/"${RUNID}" \
    "${WORKING_DIR}"/fastqscreen/"${RUNID}"

## - Copy fastq reads to Rsg_reads
fn_log "Exporting fastq reads"
rsync "${WORKING_DIR}"/fastq/"${RUNID}"/ "${SSH_HOSTNAME}":"${DESTINATION}"/run_"${RUNID}"/ --recursive

## - Copy reports to Rsg_reads/reports
rsync "${WORKING_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html "${SSH_HOSTNAME}":"${DESTINATION}"/run_"${RUNID}"/MultiQC_"${RUNID}".html

## - Enable Read/Write for all files
ssh "${SSH_HOSTNAME}" chmod -R u=rwX,g=rwX,o=rX "${DESTINATION}"/run_"${RUNID}"

## - Notify end of new run being processed
fn_log "Done!"
email_finish "${RUNID}"

## - Cleaning up big files
# rm -r "${WORKING_DIR}"/fastq/"${RUNID}"/
# rm -r "${WORKING_DIR}"/runs/"${RUNID}"/

## - Wrap up run processing
echo "${RUN}" >> "${WORKING_DIR}"/RUNS_ACHIEVED
rm "${WORKING_DIR}"/PROCESSING
