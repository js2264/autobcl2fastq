#!/bin/bash

#SBATCH --cpus-per-task 12
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

# SSH_HOSTNAME=sftpcampus
# BASE_DIR=/pasteur/zeus/projets/p02/rsg_fast/jaseriza/autobcl2fastq
# RUN=''

RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
RUNNB=`echo "${RUN}" | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
RUNHASH=`echo "${RUN}" | sed 's,.*_,,g'`
RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

function email_start {
    RUNDATE=`echo ${1} | sed 's,_.*,,g'`
    RUNNB=`echo ${1} | sed 's,.*_\([0-9][0-9][0-9][0-9]\)_.*,\1,g'`
    RUNHASH=`echo ${1} | sed 's,.*_,,g'`
    RUNID="${RUNDATE}_${RUNNB}_${RUNHASH}"
    rsync "${SSH_HOSTNAME}":/pasteur/gaia/projets/p01/nextseq/${RUN}/SampleSheet.csv tmp
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
        -a "${BASE_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv \
        -a "${BASE_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html \
        ${EMAIL}
}

## ------------------------------------------------------------------
## -------- PROCESSING ----------------------------------------------
## ------------------------------------------------------------------

## - Start processing
touch "${BASE_DIR}"/PROCESSING

## - Notify start of new run being processed
email_start "${RUN}"

## - Cp entire run folder from nextseq repo to maestro ($BASE_DIR)
echo "Fetching seq. run"
rsync "${SSH_HOSTNAME}":/pasteur/gaia/projets/p01/nextseq/"${RUN}"/ "${BASE_DIR}/${RUNID}"/ --recursive --verbose --progress

## - Fix sample sheet
echo "Fixing sample sheet"
mkdir -p "${BASE_DIR}"/samplesheets
sed 's/,,,,,,,//g' "${BASE_DIR}"/"${RUNID}"/SampleSheet.csv \
    | sed 's/\[\(.*\)\],/\[\1\]/' \
    | sed 's/^\([0-9]*\)\,/\1/g' \
    | sed 's/^//g' \
    | sed 's/^$//g' \
    | grep -v -P "^," > "${BASE_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv

## - Run bcl2fastq
echo "Running bcl2fastq"
mkdir -p "${BASE_DIR}"/fastq/"${RUNID}"/
bcl2fastq \
    --no-lane-splitting \
    -R "${BASE_DIR}"/"${RUNID}"/ \
    -o "${BASE_DIR}"/fastq/"${RUNID}"/ \
    --sample-sheet "${BASE_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv \
    --loading-threads 4 \
    --processing-threads 4 \
    --writing-threads 4
cp "${BASE_DIR}"/samplesheets/SampleSheet_"${RUNID}".csv "${BASE_DIR}"/fastq/"${RUNID}"/SampleSheet_"${RUNID}".csv

## - Run FastQC for all the samples
#Adaptors from https://www.outils.genomique.biologie.ens.fr/leburon/downloads/aozan-example/adapters.fasta
echo "Running FastQC"
mkdir -p "${BASE_DIR}"/fastqc/"${RUNID}"
fastqc \
    --outdir "${BASE_DIR}"/fastqc/"${RUNID}" \
    --noextract \
    --threads 12 \
    --adapters "${BASE_DIR}"/adapters.txt \
    "${BASE_DIR}"/fastq/"${RUNID}"/*/*fastq.gz

## - Run fastq_screen for all the samples
echo "Running fastq_screen"
mkdir -p "${BASE_DIR}"/fastqscreen/"${RUNID}"
fastq_screen \
    --outdir "${BASE_DIR}"/fastqscreen/"${RUNID}" \
    --conf "${BASE_DIR}"/fastq_screen.conf \
    --threads 12 \
    "${BASE_DIR}"/fastq/"${RUNID}"/*/*fastq.gz

## - Run MultiQC to aggregate results (bcl2fastq, fastqc, fastq_screen)
echo "Running multiqc"
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
echo "Exporting fastq reads"
rsync "${BASE_DIR}"/fastq/"${RUNID}"/ "${SSH_HOSTNAME}":/pasteur/projets/policy02/Rsg_reads/run_"${RUNID}"/ --recursive --verbose --progress

## - Copy reports to Rsg_reads/reports
rsync "${BASE_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html "${SSH_HOSTNAME}":/pasteur/projets/policy02/Rsg_reads/run_"${RUNID}"/MultiQC_"${RUNID}".html

## - Enable Read/Write for all files
ssh "${SSH_HOSTNAME}" chmod -R u=rwX,g=rwX,o=rX /pasteur/projets/policy02/Rsg_reads/run_"${RUNID}"

## - Notify end of new run being processed
email_finish "${RUN}"

## - Wrap up run processing
rm "${BASE_DIR}"/PROCESSING
echo "${RUN}" >> "${BASE_DIR}"/RUNS_ACHIEVED
