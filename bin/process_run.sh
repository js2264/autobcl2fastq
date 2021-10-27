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
RUNID="NSQ${RUNNB}_${RUNDATE}"

## ------------------------------------------------------------------
## -------- HELPER FUNCTIONS ----------------------------------------
## ------------------------------------------------------------------

function fix_samplesheet {
    rclone copy GDriveJS:/rsg/rsgsheet_NSQ"${1}".xlsx "${WORKING_DIR}"/rsgsheets/
    cp "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}".xlsx "${WORKING_DIR}"/samplesheets/rsgsheet_NSQ"${1}".xlsx
    xlsx2csv "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}".xlsx | cut -f 1-8 -d, | grep -v ^, | grep -v ^[0-9]*,, > "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}".csv
    cmds=`echo -e "
    x <- read.csv('"${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}".csv') ;
    y <- read.csv('${BASE_DIR}/indices.txt', header = TRUE, sep = '\\\\\t') ; 
    x <- merge(x, y, by = 'barcode_well') ;
    z <- data.frame(Sample_ID = x\\$sample_id, Sample_Name = x\\$sample_id, Sample_Plate = '', Sample_Well = x\\$barcode_well, I7_Index_ID = '', index = x\\$i7_sequence, I5_Index_ID = '', index2 = x\\$i5_sequence, Sample_Project = gsub('[0-9].*', '', x\\$sample_id)) ;
    write.table(z, '"${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}"_fixed.csv', quote = FALSE, row.names = FALSE, col.names = TRUE, sep = ',')
    "`
    Rscript <(echo "${cmds}")
    cp "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}".xlsx "${WORKING_DIR}"/samplesheets/
    echo "[Header]
    Date,"${RUNDATE}"
    Workflow,GenerateFASTQ
    Experiment Name,NSQ"${1}"

    [Data]
    " | sed 's/^[ \t]*//' > "${2}"
    cat "${WORKING_DIR}"/rsgsheets/rsgsheet_NSQ"${1}"_fixed.csv >> "${2}"

    rm -rf "${WORKING_DIR}"/rsgsheets/
}

function email_finish {
    echo "Files stored in ${DESTINATION}"/run_"${RUNID}" | mailx \
        -s "Finished processing run ${RUNID} with autobcl2fastq" \
        -a "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv \
        -a "${WORKING_DIR}"/multiqc/"${RUNID}"/"${RUNID}"_multiqc_report.html \
        ${EMAIL}
}

function fn_log {
    echo -e "`date "+%y-%m-%d %H:%M:%S"` [INFO] $@"
}

## ------------------------------------------------------------------
## -------- PROCESSING ----------------------------------------------
## ------------------------------------------------------------------

## - Cp entire run folder from nextseq repo to maestro ($WORKING_DIR)
fn_log "Fetching sequencing run data"
mkdir -p "${WORKING_DIR}"/runs
rsync "${SSH_HOSTNAME}":"${SOURCE}"/"${RUN}"/ "${WORKING_DIR}"/runs/"${RUNID}"/ --recursive

## - Download corresponding sample sheet from GDrive:rsg/
fn_log "Fetching/fixing sample sheet"
fix_samplesheet "${RUNNB}" "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv

## - Run bcl2fastq
fn_log "Running bcl2fastq"
mkdir -p "${WORKING_DIR}"/fastq/"${RUNID}"/
bcl2fastq \
    --no-lane-splitting \
    -R "${WORKING_DIR}"/runs/"${RUNID}"/ \
    -o "${WORKING_DIR}"/fastq/"${RUNID}"/ \
    --sample-sheet "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv \
    --loading-threads 6 \
    --processing-threads 6 \
    --writing-threads 6
cp "${WORKING_DIR}"/samplesheets/SampleSheet_NSQ"${RUNNB}".csv "${WORKING_DIR}"/fastq/"${RUNID}"/SampleSheet_NSQ"${RUNNB}".csv

## - Rename all fastqs
fn_log "Fixing fastq names"
for FILE in `find "${WORKING_DIR}"/fastq/"${RUNID}"/ -iname "*.fastq.gz"`
do
    newfile=`echo ${FILE} | sed -e 's,_001.fastq.gz,.fq.gz,' | sed -e 's,_S[0-9]_R,_R,' | sed -e 's,_S[0-9][0-9]_R,_R,'`
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
ssh "${SSH_HOSTNAME}" chmod -R u=rwX,g=rwX,o= "${DESTINATION}"/run_"${RUNID}"

## - Notify end of processing
email_finish

## - Cleaning up big files
rm -r "${WORKING_DIR}"/runs/"${RUNID}"/
rm -r "${WORKING_DIR}"/fastq/"${RUNID}"/

## - Wrap up run processing
echo "${RUN}" >> "${WORKING_DIR}"/PROCESSED_RUNS
rm "${WORKING_DIR}"/PROCESSING
ssh "${SSH_HOSTNAME}" touch "${DESTINATION}"/run_"${RUNID}"/DONE

fn_log "Done!"
