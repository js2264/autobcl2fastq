#!/bin/bash

#SBATCH --cpus-per-task 20
#SBATCH --mem 48G

## ------------------------------------------------------------------
## -------- DEPENDENCIES --------------------------------------------
## ------------------------------------------------------------------

module purge
module load bcl2fastq/2.20.0
module load graalvm/ce-java19-22.3.1
module load fastqc/0.11.9
module load bowtie2/2.1.0
module load MultiQC/1.9
module load fastq_screen/v0.14.0

## ------------------------------------------------------------------
## -------- ENV. VARIABLES ------------------------------------------
## ------------------------------------------------------------------

RUNDATE=`echo "${RUN}" | sed 's,_.*,,g'`
SEQID=`echo "${RUN}" | sed "s,.*${RUNDATE}_,,g" | sed "s,_.*,,g"`
RUNNB=`echo "${RUN}" | sed "s,.*${SEQID}_,,g" | sed "s,_.*,,g"`
RUNHASH=`echo "${RUN}" | sed "s,.*${RUNNB}_,,g" | sed "s,_.*,,g"`
RUNID="${RUNNB}_${RUNDATE}_${RUNHASH}"

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

function fn_log {
    echo -e "`date "+%y-%m-%d %H:%M:%S"` [INFO] $@"
}

function cleanup() {
    local status=$?
    if ( test "${status}" -gt 0 ) ; then
        echo "Caught signal ${status} ... cleaning up & quitting."
        rm -f ${WORKING_DIR}/PROCESSING
        exit 1
    fi
    exit 0
}

## ------------------------------------------------------------------
## ------------------- CLEAN UP BEFORE EXIT -------------------------
## ------------------------------------------------------------------

trap cleanup EXIT INT TERM

## ------------------------------------------------------------------
## -------- PROCESSING ----------------------------------------------
## ------------------------------------------------------------------

## - Run bcl2fastq
fn_log "Running bcl2fastq"
mkdir -p "${WORKING_DIR}"/fastq/"${RUNID}"/
bcl2fastq \
    --no-lane-splitting \
    -R "${WORKING_DIR}"/runs/"${RUN}"/ \
    -o "${WORKING_DIR}"/fastq/"${RUNID}"/ \
    --sample-sheet "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv \
    --loading-threads 6 \
    --processing-threads 6 \
    --writing-threads 6
cp "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv "${WORKING_DIR}"/fastq/"${RUNID}"/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv

## - Rename all fastqs (with Nextseq nxq extension)
fn_log "Fixing fastq names"
for FILE in `find "${WORKING_DIR}"/fastq/"${RUNID}"/ -iname "*.fastq.gz"`
do
    newfile=`echo ${FILE} | sed -e 's,_001.fastq.gz,.fq.gz,' | sed -e 's,_S[0-9]_R,_nxq_R,' | sed -e 's,_S[0-9][0-9]_R,_nxq_R,'`
    mv "${FILE}" "${newfile}"
done

## - Run FastQC for all the samples
#Adaptors adapted from https://www.outils.genomique.biologie.ens.fr/leburon/downloads/aozan-example/adapters.fasta
fn_log "Running FastQC"
mkdir -p "${WORKING_DIR}"/fastqc/"${RUNID}"
fastqc \
    --outdir "${WORKING_DIR}"/fastqc/"${RUNID}" \
    --noextract \
    --threads 12 \
    --adapters "${BASE_DIR}"/adapters.txt \
    "${WORKING_DIR}"/fastq/"${RUNID}"/*/*fq.gz 1>&2

## - Run fastq_screen for all the samples
fn_log "Running fastq_screen"
mkdir -p "${WORKING_DIR}"/fastqscreen/"${RUNID}"
fastq_screen \
    --outdir "${WORKING_DIR}"/fastqscreen/"${RUNID}" \
    --conf "${BASE_DIR}"/fastq_screen.conf \
    --threads 12 \
    "${WORKING_DIR}"/fastq/"${RUNID}"/*/*fq.gz

## - Run MultiQC to aggregate results (bcl2fastq, fastqc, fastq_screen)
fn_log "Running multiqc"
mkdir -p "${WORKING_DIR}"/multiqc/"${RUNID}"
multiqc \
    --title "${RUNID}" \
    --outdir "${WORKING_DIR}"/multiqc/"${RUNID}" \
    --force \
    --verbose \
    --module bcl2fastq \
    --module fastq_screen \
    --module fastqc \
    "${WORKING_DIR}"/fastq/"${RUNID}" \
    "${WORKING_DIR}"/fastqc/"${RUNID}" \
    "${WORKING_DIR}"/fastqscreen/"${RUNID}" 1>&2

## - Copy fastq reads to Rsg_reads/run.../
fn_log "Exporting fastq reads"
rsync "${WORKING_DIR}"/fastq/"${RUNID}"/ "${SSH_HOSTNAME}":"${DESTINATION}"/run_"${RUNID}"/ --recursive

## - Copy reports to Rsg_reads/run.../reports
rsync "${WORKING_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html "${SSH_HOSTNAME}":"${DESTINATION}"/run_"${RUNID}"/MultiQC_"${RUNID}".html

## - Enable Read/Write for all files
ssh "${SSH_HOSTNAME}" touch "${DESTINATION}"/run_"${RUNID}"/DONE
ssh "${SSH_HOSTNAME}" chmod -R u=rwX,g=rwX,o=rX "${DESTINATION}"/run_"${RUNID}"

## - Notify end of processing
echo "Files stored in ${DESTINATION}"/run_"${RUNID}" | mailx \
    -s "[CLUSTER INFO] Finished processing run ${RUNID} with autobcl2fastq" \
    -a "${WORKING_DIR}"/samplesheets/SampleSheet_"${RUNNB}"_"${RUNDATE}"_"${RUNHASH}".csv \
    -a "${WORKING_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html \
    ${EMAIL}

## - Cleaning up big files
fn_log "Cleaning up big files"
# rm -r "${WORKING_DIR}"/runs/"${RUN}"/
# rm -r "${WORKING_DIR}"/fastq/"${RUNID}"/

## - Wrap up run processing
rm "${WORKING_DIR}"/PROCESSING

fn_log "Done!"
exit 0
