#!/usr/bin/env nextflow

/*
================================================================================
                              nf-core/circrna
================================================================================
Started August 2020.
Dev version to nf-core Feb 2021.

--------------------------------------------------------------------------------
 @Homepage
 https://github.com/nf-core/circrna
 -------------------------------------------------------------------------------
 @Documentation
 https://nf-co.re/circrna
--------------------------------------------------------------------------------
 @Authors
 Barry Digby (@BarryDigby)
--------------------------------------------------------------------------------
*/

log.info Headers.nf_core(workflow, params.monochrome_logs)

/*
================================================================================
                              Print Help
================================================================================
*/

//def json_schema = "$projectDir/nextflow_schema.json"
if (params.help) {
    def command = "nextflow run nf-core/circrna -profile singularity --input '*_R{1,2}.fastq.gz' --input_type 'fastq' --genome 'GRCh38' --module 'circrna_discovery, mirna_prediction, differential_expression' --tool 'CIRCexplorer2' --phenotype 'metadata.csv' "
    log.info NfcoreSchema.params_help(workflow, params, json_schema, command)
    exit 0
}

/*
================================================================================
                          Check parameters
================================================================================
*/

if (params.validate_params) {
    NfcoreSchema.validateParameters(params, json_schema, log)
}

if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)){
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(', ')}"
}

// Check Tools selected
toolList = defineToolList()
tool = params.tool ? params.tool.split(',').collect{it.trim().toLowerCase()} : []
if (!checkParameterList(tool, toolList)) exit 1, "[nf-core/circrna] error: Unknown tool selected, see --help for more information."

// Check Modules selected
moduleList = defineModuleList()
module = params.module ? params.module.split(',').collect{it.trim().toLowerCase()} : []
if (!checkParameterList(module, moduleList)) exit 1, "[nf-core/circrna] error: Unknown module selected, see --help for more information."

/*
 * The below index parameters are allowed to be empty (they will be generated if empty)
 * Mainly concerned about valid file extensions when provided (advanced checks not capable in Schema)
 */

// Check phenotype file and stage the channel
// (Must not have NA's, must have 'condition' as colname)

if(params.phenotype){
   pheno_file = file(params.phenotype)
   ch_phenotype = examine_phenotype(pheno_file)
} else {
   ch_phenotype = Channel.empty()
}

// Check BBDUK params
/*
  check adapters file exists
  check combinations of parameters have been supplied
*/

if(params.trim_fastq){
   if(params.adapters){
      adapters = file(params.adapters, checkIfExists: true)
      if(!params.k && !params.ktrim || !params.k && params.ktrim || params.k && !params.ktrim){
         exit 1, "[nf-core/circrna] error: Adapter file provided for trimming but missing values for '--k' and/or '--ktrim'.Please provide values for '--k' and '--ktrim'.\n\nPlease check the parameter documentation online."
      }
    }
    if(params.trimq && !params.qtrim || !params.trimq && params.qtrim){
       exit 1, "[nf-core/circrna] error: Both '--trimq' and '--qtrim' are required to perform quality filtering - only one has been provided.\n\nPlease check the parameter documentation online."
   }
}

// Check filtering params
tools_selected = tool.size()

// Check '--tool_filter'' does not exceed number of tools selected
if(tools_selected > 1 && params.tool_filter > tools_selected){
  exit 1, "[nf-core/circrna] error: The parameter '--tool_filter' (${params.tool_filter}) exceeds the number of tools selected (${params.tool}). Please select a value less than or equal to the number of quantification tools selected ($tools_selected).\n\nPlease check the help documentation."
}

// Check Input data (if !csv choose path)

if(has_extension(params.input, "csv")){

   csv_file = file(params.input, checkIfExists: true)
   ch_input = extract_data(csv_file)

}else if(params.input && !has_extension(params.input, "csv")){

   log.info ""
   log.info "Input data log info:"
   log.info "No input sample CSV file provided, attempting to read from path instead."
   log.info "Reading input data from path: ${params.input}\n"
   log.info ""

   ch_input = retrieve_input_paths(params.input, params.input_type)

}

/*
================================================================================
                        PRINTING PARAMETER SUMMARY
================================================================================
*/

log.info NfcoreSchema.params_summary_log(workflow, params, json_schema)

// Has the run name been specified by the user?
// This has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) custom_runName = workflow.runName

def summary = [:]
if (workflow.revision)        summary['Pipeline Release']    = workflow.revision
summary['Run Name']          = custom_runName ?: workflow.runName
if (workflow.containerEngine) summary['Container'] = "${workflow.containerEngine} - ${workflow.container}"
summary['Max Resources']     = "${params.max_memory} memory, ${params.max_cpus} cpus, ${params.max_time} time per job"
summary['Config Files']   = workflow.configFiles.join(', ')
summary['Launch dir']  = workflow.launchDir
summary['Output dir']  = params.outdir
summary['Publish dir mode']  = params.publish_dir_mode
summary['Working dir'] = workflow.workDir
summary['Script dir']  = workflow.projectDir
summary['User']        = workflow.userName

summary['Input']             = params.input
summary['Input type']        = params.input_type
summary['circRNA tool(s)']   = params.tool
summary['modules']           = params.module
if('differential_expression' in module) summary['Phenotype design'] = params.phenotype
summary['BSJ filter']        = params.bsj_reads
if(tools_selected > 1) summary['Tool filter'] = params.tool_filter
if('mirna_prediction' in module) summary['Minimum free energy'] = params.mfe

summary['Genome version'] = params.genome
if(params.fasta)           summary['Reference FASTA']   = params.fasta
if(params.gtf)             summary['Reference GTF']     = params.gtf
if(params.gene_annotation) summary['Custom annotation'] = params.gene_annotation
if(params.bowtie)    summary['Bowtie indices']    = params.bowtie
if(params.bowtie2)   summary['Bowtie2 indices']   = params.bowtie2
if(params.bwa)       summary['BWA indices']       = params.bwa
if(params.fasta_fai)       summary['SAMtoolsindex']    = params.fasta_fai
if(params.hisat2)    summary['HISAT2 indices']    = params.hisat2
if(params.star)      summary ['STAR indices']     = params.star

summary['Skip BBDUK']     = params.trim_fastq
if(params.trim_fastq){
                           summary['BBDUK']             = "Enabled"
if(params.adapters)        summary['Adapter file']      = params.adapters
if(params.k)               summary['k']                 = params.k
if(params.ktrim)           summary['ktrim']             = params.ktrim
if(params.hdist)           summary['hdist']             = params.hdist
if(params.trimq)           summary['trimq']             = params.trimq
if(params.qtrim)           summary['qtrim']             = params.qtrim
if(params.minlen)          summary['minlen']            = params.minlen
}

if('circexplorer2' in tool || 'circrna_finder' in tool || 'dcc' in tool){
if(params.alignIntronMax)                      summary['alignIntronMax']               = params.alignIntronMax
if(params.alignIntronMin)                      summary['alignIntronMin']               = params.alignIntronMin
if(params.alignMatesGapMax)                    summary['alignMatesGapMax']             = params.alignMatesGapMax
if(params.alignSJDBoverhangMin)                summary['alignSJDBoverhangMin']         = params.alignSJDBoverhangMin
if(params.alignSJoverhangMin)                  summary['alignSJoverhangMin']           = params.alignSJoverhangMin
if(params.alignSoftClipAtReferenceEnds)        summary['alignSoftClipAtReferenceEnds'] = params.alignSoftClipAtReferenceEnds
if(params.alignTranscriptsPerReadNmax)         summary['alignTranscriptsPerReadNmax']  = params.alignTranscriptsPerReadNmax
if(params.chimJunctionOverhangMin)             summary['chimJunctionOverhangMin']      = params.chimJunctionOverhangMin
if(params.chimScoreMin)                        summary['chimScoreMin']                 = params.chimScoreMin
if(params.chimScoreSeparation)                 summary['chimScoreSeparation']          = params.chimScoreSeparation
if(params.chimSegmentMin)                      summary['chimSegmentMin']               = params.chimSegmentMin
if(params.genomeLoad)                          summary['genomeLoad']                   = params.genomeLoad
if(params.limitSjdbInsertNsj)                  summary['limitSjdbInsertNsj']           = params.limitSjdbInsertNsj
if(params.outFilterMatchNminOverLread)         summary['outFilterMatchNminOverLread']  = params.outFilterMatchNminOverLread
if(params.outFilterMismatchNoverLmax)          summary['outFilterMismatchNoverLmax']   = params.outFilterMismatchNoverLmax
if(params.outFilterMultimapNmax)               summary['outFilterMultimapNmax']        = params.outFilterMultimapNmax
if(params.outFilterMultimapScoreRange)         summary['outFilterMultimapScoreRange']  = params.outFilterMultimapScoreRange
if(params.outFilterScoreMinOverLread)          summary['outFilterScoreMinOverLread']   = params.outFilterScoreMinOverLread
if(params.outSJfilterOverhangMin)              summary['outSJfilterOverhangMin']       = params.outSJfilterOverhangMin
if(params.sjdbOverhang)                        summary['sjdbOverhang']                 = params.sjdbOverhang
if(params.sjdbScore)                           summary['sjdbScore']                    = params.sjdbScore
if(params.winAnchorMultimapNmax)               summary['winAnchorMultimapNmax']        = params.winAnchorMultimapNmax
}

if(workflow.profile.contains('awsbatch')){
    summary['AWS Region'] = params.awsregion
    summary['AWS Queue']  = params.awsqueue
    summary['AWS CLI']    = params.awscli
}

if(params.email || params.email_on_fail){
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-circrna-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/circrna Workflow Summary'
    section_href: 'https://github.com/nf-core/circrna'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }


/*
================================================================================
                            Stage Parameters
================================================================================
*/

params.fasta     = params.genome ? params.genomes[params.genome].fasta ?: false : false
params.fasta_fai = params.genome ? params.genomes[params.genome].fasta_fai ?: false : false
params.gtf       = params.genome ? params.genomes[params.genome].gtf ?: false : false
params.bwa       = params.genome && 'ciriquant' in tool ? params.genomes[params.genome].bwa ?: false : false
params.star      = params.genome && ('circexplorer2' || 'dcc' || 'circrna_finder' in tool) ? params.genomes[params.genome].star ?: false : false
params.bowtie    = params.genome && 'mapsplice' in tool ? params.genomes[params.genome].bowtie ?: false : false
params.bowtie2   = params.genome && 'find_circ' in tool ? params.genomes[params.genome].bowtie2 ?: false : false
params.mature    = params.genome && 'mirna_prediction' in module ? params.genomes[params.genome].mature ?: false : false
params.species   = params.genome ? params.genomes[params.genome].species_id?: false : false

ch_fasta = params.fasta ? Channel.value(file(params.fasta)) : 'null'
ch_gtf = params.gtf ? Channel.value(file(params.gtf)) : 'null'
ch_mature = params.mature && 'mirna_prediction' in module ? Channel.value(file(params.mature)) : 'null'
ch_species = params.genome ? Channel.value(params.species) : Channel.value(params.species)

/*
================================================================================
                            BUILD INDICES
================================================================================
*/

process BWA_INDEX {
    tag "${fasta}"
    label 'proces_medium'
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/${it}" : null }

    when:
    !params.bwa && !params.genome && params.fasta && 'ciriquant' in tool && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta

    output:
    file("BWAIndex") into bwa_built

    script:
    """
    mkdir -p BWAIndex
    bwa index $fasta -p BWAIndex/${fasta.baseName}
    """
}

ch_bwa = params.genome ? Channel.value(file(params.bwa)) : params.bwa ? Channel.value(file(params.bwa)) : bwa_built

process SAMTOOLS_INDEX {
    tag "${fasta}"
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/${it}" : null }

    when:
    !params.fasta_fai && params.fasta

    input:
    file(fasta) from ch_fasta

    output:
    file("${fasta}.fai") into fai_built

    script:
    """
    samtools faidx ${fasta}
    """
}

ch_fai = params.genome ? Channel.value(file(params.fasta_fai)) : params.fasta_fai ? Channel.value(file(params.fasta_fai)) : fai_built

process HISAT2_INDEX {
    tag "${fasta}"
    label 'process_medium'
    publishDir params.outdir, mode: params.publish_dir_mode,
       saveAs: { params.save_reference ? "reference_genome/Hisat2Index/${it}" : null }

    when:
    !params.hisat && params.fasta && ('differential_expression' in module || 'ciriquant' in tool)

    input:
    file(fasta) from ch_fasta

    output:
    file("${fasta.baseName}.*.ht2") into hisat_built
    val("${launchDir}/${params.outdir}/reference_genome/Hisat2Index") into hisat_path

    script:
    """
    hisat2-build \\
        -p ${task.cpus} \\
        $fasta \\
        ${fasta.baseName}
    """
}

ch_hisat = params.hisat ? Channel.value(file(params.hisat)) : hisat_path

process STAR_INDEX {
    tag "${fasta}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/${it}" : null }

    when:
    !params.star && params.fasta && params.gtf && ('circexplorer2' in tool || 'circrna_finder' in tool || 'dcc' in tool) && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta
    file(gtf) from ch_gtf

    output:
    file("STARIndex") into star_built

    script:
    """
    mkdir -p STARIndex

    STAR \\
        --runMode genomeGenerate \\
        --runThreadN ${task.cpus} \\
        --sjdbOverhang ${params.sjdbOverhang} \\
        --sjdbGTFfile $gtf \\
        --genomeDir STARIndex/ \\
        --genomeFastaFiles $fasta
    """
}

ch_star = params.genome ? Channel.value(file(params.star)) : params.star ? Channel.value(file(params.star)) : star_built

process BOWTIE_INDEX {
    tag "${fasta}"
    label 'process_medium'
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/BowtieIndex/${it}" : null }

    when:
    !params.bowtie && params.fasta && 'mapsplice' in tool && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta

    output:
    file ("${fasta.baseName}.*") into bowtie_built

    script:
    """
    bowtie-build \\
        --threads ${task.cpus} \\
        $fasta \\
        ${fasta.baseName}
    """
}

ch_bowtie = params.genome ? Channel.fromPath("${params.bowtie}*") : params.bowtie ? Channel.fromPath("${params.bowtie}*", checkIfExists: true).ifEmpty { exit 1, "[nf-core/circrna] error: Bowtie index directory not found: ${params.bowtie}"} : bowtie_built

process BOWTIE2_INDEX {
    tag "${fasta}"
    label 'process_medium'
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/Bowtie2Index/${it}" : null }

    when:
    !params.bowtie2 && params.fasta && 'find_circ' in tool && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta

    output:
    file ("${fasta.baseName}.*") into bowtie2_built

    script:
    """
    bowtie2-build \\
        --threads ${task.cpus} \\
        $fasta \\
        ${fasta.baseName}
    """
}

ch_bowtie2 = params.genome ? Channel.fromPath("${params.bowtie2}*") : params.bowtie2 ? Channel.fromPath("${params.bowtie2}*", checkIfExists: true).ifEmpty { exit 1, "[nf-core/circrna] error: Bowtie2 index directory not found: ${params.bowtie2}"} : bowtie2_built
(ch_bowtie2_anchors, ch_bowtie2_find_circ) = ch_bowtie2.into(2)

process SEGEMEHL_INDEX{
    tag "${fasta}"
    label 'proces_medium'
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/SegemehlIndex/${it}" : null }

    when:
    !params.segemehl && params.fasta && 'segemehl' in tool && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta

    output:
    file("${fasta.baseName}.idx") into segemehl_built

    script:
    """
    segemehl.x \\
        -t ${task.cpus} \\
        -d $fasta \\
        -x "${fasta.baseName}.idx"
    """
}

ch_segemehl = params.segemehl ? Channel.value(file(params.segemehl)) : segemehl_built

/*
================================================================================
                           Misc circRNA Requirements
================================================================================
*/

process FILTER_GTF{
    tag"${gtf}"

    when:
    'circrna_discovery' in module

    input:
    file(gtf) from ch_gtf

    output:
    file("filt.gtf") into ch_gtf_filtered

    script:
    """
    grep -vf ${projectDir}/bin/unwanted_biotypes.txt $gtf > filt.gtf
    """
}

process SPLIT_CHROMOSOMES{
    tag "${fasta}"
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/chromosomes/${it}" : null }

    when:
    params.fasta && ('mapsplice' in tool || 'find_circ' in tool) && 'circrna_discovery' in module

    input:
    file(fasta) from ch_fasta

    output:
    path("*.fa", includeInputs:true) into publish_chromosomes
    val("${launchDir}/${params.outdir}/reference_genome/chromosomes") into chromosomes_dir

    shell:
    '''
    ## Add catch for test datasets (uses only 1 chr, no action needed -> includeInputs:true)
    n_chr=$(grep '>' !{fasta} | wc -l)

    if [[ $n_chr -gt 1 ]];
    then
      awk '/^>/ {F=substr($0, 2, length($0))".fa"; print >F;next;} {print >> F;}' < !{fasta}
      rm !{fasta}
    else
      :
    fi
    '''
}

ch_chromosomes = params.chromosomes ? Channel.value(params.chromosomes) : chromosomes_dir

process CIRIQUANT_YML{

    when:
    'ciriquant' in tool && 'circrna_discovery' in module

    input:
    file(gtf) from ch_gtf
    file(fasta) from ch_fasta
    file(bwa) from ch_bwa
    val(hisat) from ch_hisat

    output:
    file("travis.yml") into ch_ciriquant_yml

    script:
    bwa_prefix = fasta.toString() == 'genome.fa' ? fasta.toString() : fasta.toString() - ~/.(fa|fasta)$/
    hisat_prefix = fasta.toString() - ~/.(fa|fasta)$/
    fasta_path = fasta.toRealPath()
    gtf_path = gtf.toRealPath()
    bwa_path = bwa.toRealPath()
    """
    BWA=`whereis bwa | cut -f2 -d':'`
    HISAT2=`whereis hisat2 | cut -f2 -d':'`
    STRINGTIE=`whereis stringtie | cut -f2 -d':'`
    SAMTOOLS=`whereis samtools | cut -f2 -d':' | awk '{print \$1}'`

    touch travis.yml
    printf "name: ciriquant\n\
    tools:\n\
     bwa: \$BWA\n\
     hisat2: \$HISAT2\n\
     stringtie: \$STRINGTIE\n\
     samtools: \$SAMTOOLS\n\n\
    reference:\n\
     fasta: ${fasta_path}\n\
     gtf: ${gtf_path}\n\
     bwa_index: ${bwa_path}/${bwa_prefix}\n\
     hisat_index: ${hisat}/${hisat_prefix}" >> travis.yml
    """
}

process GENE_ANNOTATION{
    tag "${gtf}"
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_reference ? "reference_genome/${it}" : null }

    when:
    !params.gene_annotation && params.gtf && ('circexplorer2' || 'mapsplice' in tool) && 'circrna_discovery' in module

    input:
    file(gtf) from ch_gtf

    output:
    file("${gtf.baseName}.txt") into ch_gene

    script:
    """
    gtfToGenePred -genePredExt -geneNameAsName2 ${gtf} ${gtf.baseName}.genepred
    perl -alne '\$"="\t";print "@F[11,0..9]"' ${gtf.baseName}.genepred > ${gtf.baseName}.txt
    """
}

/*
================================================================================
                            Stage Input Data
================================================================================
*/

if(params.input_type == 'bam'){

   process BAM_TO_FASTQ{
        tag "${base}"
        label 'process_medium'
        publishDir params.outdir, mode: params.publish_dir_mode,
            saveAs: { params.save_qc_intermediates ? "quality_control/SamToFastq/${it}" : null }

        input:
        tuple val(base), file(bam) from ch_input

        output:
        tuple val(base), file('*.fq.gz') into fastq_built

        script:
        """
        picard \\
            -Xmx${task.memory.toGiga()}g \\
            SamToFastq \\
            I=$bam \\
            F=${base}_R1.fq.gz \\
            F2=${base}_R2.fq.gz \\
            VALIDATION_STRINGENCY=LENIENT
        """
   }

   (fastqc_reads, trimming_reads, raw_reads) = fastq_built.into(3)

}else if(params.input_type == 'fastq'){

   (fastqc_reads, trimming_reads, raw_reads) = ch_input.into(3)

}

process FASTQC_RAW {
    tag "${base}"
    label 'process_low'
    label 'py3'

    input:
    tuple val(base), file(fastq) from fastqc_reads

    output:
    file("*.{html,zip}") into fastqc_raw

    script:
    """
    fastqc -q $fastq --threads ${task.cpus}
    """
}

/*
================================================================================
                                    BBDUK
================================================================================
*/

if(params.trim_fastq){

   process BBDUK {
       tag "${base}"
       label 'process_medium'
       publishDir params.outdir, mode: params.publish_dir_mode, pattern: "*.fq.gz",
           saveAs: { params.save_qc_intermediates ? "quality_control/BBDUK/${it}" : null }

       input:
       tuple val(base), file(fastq) from trimming_reads
       path adapters from params.adapters

       output:
       tuple val(base), file('*.trim.fq.gz') into trim_reads_ch
       file("*BBDUK.txt") into bbduk_stats_ch

       script:
       def adapter = params.adapters ? "ref=${params.adapters}" : ''
       def k = params.k ? "k=${params.k}" : ''
       def ktrim = params.ktrim ? "ktrim=${params.ktrim}" : ''
       def hdist = params.hdist ? "hdist=${params.hdist}" : ''
       def trimq = params.trimq ? "trimq=${params.trimq}" : ''
       def qtrim = params.qtrim ? "qtrim=${params.qtrim}" : ''
       def minlen = params.minlen ? "minlen=${params.minlen}" : ''
       """
       bbduk.sh \\
           -Xmx${task.memory.toGiga()}g \\
           threads=${task.cpus} \\
           in1=${fastq[0]} \\
           in2=${fastq[1]} \\
           out1=${base}_R1.trim.fq.gz \\
           out2=${base}_R2.trim.fq.gz \\
           $adapter \\
           $k \\
           $ktrim \\
           $trimq \\
           $qtrim \\
           $minlen \\
           stats=${base}_BBDUK.txt
       """
   }

   // trimmed reads into 2 channels:
   (fastqc_trim_reads, aligner_reads) = trim_reads_ch.into(2)

   process FASTQC_BBDUK {
       tag "${base}"
       label 'process_low'
       label 'py3'

       input:
       tuple val(base), file(fastq) from fastqc_trim_reads

       output:
       file ("*.{html,zip}") into fastqc_trimmed

       script:
       """
       fastqc -q $fastq --threads ${task.cpus}
       """
   }

}else if(!params.trim_fastq){
   aligner_reads = raw_reads
}

(star_pass1_reads, star_pass2_reads, find_circ_reads, ciriquant_reads, mapsplice_reads, segemehl_reads, dcc_mate1_reads, dcc_mate2_reads, hisat_reads) = aligner_reads.into(9)

/*
================================================================================
                     circRNA quantification + annotation
================================================================================
*/

process CIRIQUANT{
    tag "${base}"
    label 'process_high'

    publishDir "${params.outdir}/circrna_discovery/CIRIquant/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/CIRIquant/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/CIRIquant/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/CIRIquant/intermediates/${it}" : null }

    when:
    'ciriquant' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(fastq) from ciriquant_reads
    file(ciriquant_yml) from ch_ciriquant_yml
    file(gtf_filt) from ch_gtf_filtered
    file(fasta) from ch_fasta
    file(fai) from ch_fai

    output:
    tuple val(base), file("${base}_ciriquant.bed") into ciriquant_results
    tuple val(base), file("${base}") into ciriquant_intermediates
    tuple val(base), file("${base}.bed") into ciriquant_annotated
    tuple val(base), file("fasta/*") into ciriquant_fasta
    tuple val(base), file("${base}.log") into ciriquant_annotation_logs

    script:
    """
    CIRIquant \\
        -t ${task.cpus} \\
        -1 ${fastq[0]} \\
        -2 ${fastq[1]} \\
        --config $ciriquant_yml \\
        --no-gene \\
        -o ${base} \\
        -p ${base}

    cp ${base}/${base}.gtf .

    ## extract counts (convert float/double to int [no loss of information])
    grep -v "#" ${base}.gtf | awk '{print \$14}' | cut -d '.' -f1 > counts
    grep -v "#" ${base}.gtf | awk -v OFS="\t" '{print \$1,\$4,\$5,\$7}' > ${base}.tmp
    paste ${base}.tmp counts > ${base}_unfilt.bed

    ## filter bsj_reads
    awk '{if(\$5 >= ${params.bsj_reads}) print \$0}' ${base}_unfilt.bed > ${base}_filt.bed
    grep -v '^\$' ${base}_filt.bed > ${base}_ciriquant

    ## correct offset bp position
    awk -v OFS="\t" '{\$2-=1;print}' ${base}_ciriquant > ${base}_ciriquant.bed

    rm ${base}.gtf

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_ciriquant.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences (bedtools does not like the extra annotation info - split will not work properly)
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process STAR_1PASS{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/STAR/1st_Pass/${it}" : null }

    when:
    ('circexplorer2' in tool || 'circrna_finder' in tool || 'dcc' in tool) && 'circrna_discovery' in module

    input:
    tuple val(base), file(reads) from star_pass1_reads
    file(star_idx) from ch_star

    output:
    file("${base}/*SJ.out.tab") into sjdb_ch
    file("${base}") into star_1st_pass_output

    script:
    def readFilesCommand = reads[0].toString().endsWith('.gz') ? "--readFilesCommand zcat" : ''
    """
    mkdir -p ${base}

    STAR \\
        --alignIntronMax ${params.alignIntronMax} \\
        --alignIntronMin ${params.alignIntronMin} \\
        --alignMatesGapMax ${params.alignMatesGapMax} \\
        --alignSJDBoverhangMin ${params.alignSJDBoverhangMin} \\
        --alignSJoverhangMin ${params.alignSJoverhangMin} \\
        --alignSoftClipAtReferenceEnds ${params.alignSoftClipAtReferenceEnds} \\
        --alignTranscriptsPerReadNmax ${params.alignTranscriptsPerReadNmax} \\
        --chimJunctionOverhangMin ${params.chimJunctionOverhangMin} \\
        --chimOutType Junctions SeparateSAMold \\
        --chimScoreMin ${params.chimScoreMin} \\
        --chimScoreSeparation ${params.chimScoreSeparation} \\
        --chimSegmentMin ${params.chimSegmentMin} \\
        --genomeDir ${star_idx} \\
        --genomeLoad ${params.genomeLoad} \\
        --limitSjdbInsertNsj ${params.limitSjdbInsertNsj} \\
        --outFileNamePrefix ${base}/${base}. \\
        --outFilterMatchNminOverLread ${params.outFilterMatchNminOverLread} \\
        --outFilterMismatchNoverLmax ${params.outFilterMismatchNoverLmax} \\
        --outFilterMultimapNmax ${params.outFilterMultimapNmax} \\
        --outFilterMultimapScoreRange ${params.outFilterMultimapScoreRange} \\
        --outFilterScoreMinOverLread ${params.outFilterScoreMinOverLread} \\
        --outFilterType BySJout \\
        --outReadsUnmapped None \\
        --outSAMtype BAM SortedByCoordinate \\
        --outSAMunmapped Within \\
        --outSJfilterOverhangMin ${params.outSJfilterOverhangMin} \\
        ${readFilesCommand} \\
        --readFilesIn ${reads} \\
        --runThreadN ${task.cpus} \\
        --sjdbScore ${params.sjdbScore} \\
        --winAnchorMultimapNmax ${params.winAnchorMultimapNmax}
    """
}

process SJDB_FILE{
    tag "${sjdb}"
    publishDir params.outdir, mode: params.publish_dir_mode,
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/STAR/SJFile/${it}" : null }

    when:
    ('circexplorer2' in tool || 'circrna_finder' in tool || 'dcc' in tool) && 'circrna_discovery' in module

    input:
    file(sjdb) from sjdb_ch

    output:
    file("*SJFile.tab") into sjdbfile_ch

    shell:
    '''
    base=$(basename !{sjdb} .SJ.out.tab)
    awk 'BEGIN {OFS="\t"; strChar[0]="."; strChar[1]="+"; strChar[2]="-";} {if($5>0){print $1,$2,$3,strChar[$4]}}' !{sjdb} > ${base}.SJFile.tab
    '''
}

(sjdbfile_pass2, sjdbfile_mate1, sjdbfile_mate2) = sjdbfile_ch.into(3)

process STAR_2PASS{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/STAR/2nd_Pass/${it}" : null }

    when:
    ('circexplorer2' in tool || 'circrna_finder' in tool || 'dcc' in tool) && 'circrna_discovery' in module

    input:
    tuple val(base), file(reads) from star_pass2_reads
    file(sjdbfile) from sjdbfile_pass2.collect()
    file(star_idx) from ch_star

    output:
    tuple val(base), file("${base}/${base}.Chimeric.out.junction") into circexplorer2_input
    tuple val(base), file("${base}") into circrna_finder_input, dcc_pairs


    script:
    def readFilesCommand = reads[0].toString().endsWith('.gz') ? "--readFilesCommand zcat" : ''
    """
    mkdir -p ${base}

    STAR \\
        --alignIntronMax ${params.alignIntronMax} \\
        --alignIntronMin ${params.alignIntronMin} \\
        --alignMatesGapMax ${params.alignMatesGapMax} \\
        --alignSJDBoverhangMin ${params.alignSJDBoverhangMin} \\
        --alignSJoverhangMin ${params.alignSJoverhangMin} \\
        --alignSoftClipAtReferenceEnds ${params.alignSoftClipAtReferenceEnds} \\
        --alignTranscriptsPerReadNmax ${params.alignTranscriptsPerReadNmax} \\
        --chimJunctionOverhangMin ${params.chimJunctionOverhangMin} \\
        --chimOutType Junctions SeparateSAMold \\
        --chimScoreMin ${params.chimScoreMin} \\
        --chimScoreSeparation ${params.chimScoreSeparation} \\
        --chimSegmentMin ${params.chimSegmentMin} \\
        --genomeDir ${star_idx} \\
        --genomeLoad ${params.genomeLoad} \\
        --limitSjdbInsertNsj ${params.limitSjdbInsertNsj} \\
        --outFileNamePrefix ${base}/${base}. \\
        --outFilterMatchNminOverLread ${params.outFilterMatchNminOverLread} \\
        --outFilterMismatchNoverLmax ${params.outFilterMismatchNoverLmax} \\
        --outFilterMultimapNmax ${params.outFilterMultimapNmax} \\
        --outFilterMultimapScoreRange ${params.outFilterMultimapScoreRange} \\
        --outFilterScoreMinOverLread ${params.outFilterScoreMinOverLread} \\
        --outFilterType BySJout \\
        --outReadsUnmapped None \\
        --outSAMtype BAM SortedByCoordinate \\
        --outSAMunmapped Within \\
        --outSJfilterOverhangMin ${params.outSJfilterOverhangMin} \\
        ${readFilesCommand} \\
        --readFilesIn ${reads} \\
        --runThreadN ${task.cpus} \\
        --sjdbFileChrStartEnd ${sjdbfile} \\
        --sjdbScore ${params.sjdbScore} \\
        --winAnchorMultimapNmax ${params.winAnchorMultimapNmax}
    """
}

process CIRCEXPLORER2{
    tag "${base}"
    label 'process_medium'

    publishDir "${params.outdir}/circrna_discovery/CIRCexplorer2/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/CIRCexplorer2/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/CIRCexplorer2/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/CIRCexplorer2/intermediates/${it}" : null }

    when:
    'circexplorer2' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(chimeric_reads) from circexplorer2_input
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(gene_annotation) from ch_gene
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_circexplorer2.bed") into circexplorer2_results
    tuple val(base), file("${base}") into circexplorer2_intermediates
    tuple val(base), file("${base}.bed") into circexplorer2_annotated
    tuple val(base), file("fasta/*") into circexplorer2_fasta
    tuple val(base), file("${base}.log") into circexplorer2_logs

    script:
    """
    mkdir -p ${base}

    CIRCexplorer2 parse -t STAR $chimeric_reads -b ${base}/${base}.STAR.junction.bed

    CIRCexplorer2 annotate -r $gene_annotation -g $fasta -b ${base}/${base}.STAR.junction.bed -o ${base}/${base}.txt

    awk '{if(\$13 >= ${params.bsj_reads}) print \$0}' ${base}/${base}.txt | awk -v OFS="\t" '{print \$1,\$2,\$3,\$6,\$13}' > ${base}_circexplorer2.bed

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_circexplorer2.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process CIRCRNA_FINDER{
    tag "${base}"
    label 'process_medium'
    publishDir "${params.outdir}/circrna_discovery/circRNA_Finder/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/circRNA_Finder/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/circRNA_Finder/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/circRNA_Finder/intermediates/${it}" : null }

    when:
    'circrna_finder' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(star_dir) from circrna_finder_input
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_circrna_finder.bed") into circrna_finder_results
    tuple val(base), file("${base}") into circrna_finder_intermediates
    tuple val(base), file("${base}.bed") into circrna_finder_annotated
    tuple val(base), file("fasta/*") into circrna_finder_fasta
    tuple val(base), file("${base}.log") into circrna_finder_logs

    script:
    """
    postProcessStarAlignment.pl --starDir ${star_dir}/ --outDir ./

    awk '{if(\$5 >= ${params.bsj_reads}) print \$0}' ${base}.filteredJunctions.bed | awk  -v OFS="\t" -F"\t" '{print \$1,\$2,\$3,\$6,\$5}' > ${base}_circrna_finder.bed

    mkdir -p ${base}

    mv *filteredJunctions* ${base}
    mv *.Chimeric.out.sorted.* ${base}

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_circrna_finder.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process DCC_MATE1{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "mate1",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/DCC/intermediates/${base}/${it}" : null }

    when:
    'dcc' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(reads) from dcc_mate1_reads
    file(sjdbfile) from sjdbfile_mate1.collect()
    file(star_idx) from ch_star

    output:
    tuple val(base), file("mate1") into dcc_mate1

    script:
    def readFilesCommand = reads[0].toString().endsWith('.gz') ? "--readFilesCommand zcat" : ''
    """
    mkdir -p mate1

    STAR \\
        --alignIntronMax ${params.alignIntronMax} \\
        --alignIntronMin ${params.alignIntronMin} \\
        --alignMatesGapMax ${params.alignMatesGapMax} \\
        --alignSJDBoverhangMin ${params.alignSJDBoverhangMin} \\
        --alignSJoverhangMin ${params.alignSJoverhangMin} \\
        --alignSoftClipAtReferenceEnds ${params.alignSoftClipAtReferenceEnds} \\
        --alignTranscriptsPerReadNmax ${params.alignTranscriptsPerReadNmax} \\
        --chimJunctionOverhangMin ${params.chimJunctionOverhangMin} \\
        --chimOutType Junctions SeparateSAMold \\
        --chimScoreMin ${params.chimScoreMin} \\
        --chimScoreSeparation ${params.chimScoreSeparation} \\
        --chimSegmentMin ${params.chimSegmentMin} \\
        --genomeDir ${star_idx} \\
        --genomeLoad ${params.genomeLoad} \\
        --limitSjdbInsertNsj ${params.limitSjdbInsertNsj} \\
        --outFileNamePrefix mate1/${base}. \\
        --outFilterMatchNminOverLread ${params.outFilterMatchNminOverLread} \\
        --outFilterMismatchNoverLmax ${params.outFilterMismatchNoverLmax} \\
        --outFilterMultimapNmax ${params.outFilterMultimapNmax} \\
        --outFilterMultimapScoreRange ${params.outFilterMultimapScoreRange} \\
        --outFilterScoreMinOverLread ${params.outFilterScoreMinOverLread} \\
        --outFilterType BySJout \\
        --outReadsUnmapped None \\
        --outSAMtype BAM SortedByCoordinate \\
        --outSAMunmapped Within \\
        --outSJfilterOverhangMin ${params.outSJfilterOverhangMin} \\
        ${readFilesCommand} \\
        --readFilesIn ${reads} \\
        --runThreadN ${task.cpus} \\
        --sjdbFileChrStartEnd ${sjdbfile} \\
        --sjdbScore ${params.sjdbScore} \\
        --winAnchorMultimapNmax ${params.winAnchorMultimapNmax}
    """
}

process DCC_MATE2{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "mate2",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/DCC/intermediates/${base}/${it}" : null }

    when:
    'dcc' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(reads) from dcc_mate2_reads
    file(sjdbfile) from sjdbfile_mate2.collect()
    file(star_idx) from ch_star

    output:
    tuple val(base), file("mate2") into dcc_mate2

	  script:
    def readFilesCommand = reads[0].toString().endsWith('.gz') ? "--readFilesCommand zcat" : ''
    """
    mkdir -p mate2

    STAR \\
        --alignIntronMax ${params.alignIntronMax} \\
        --alignIntronMin ${params.alignIntronMin} \\
        --alignMatesGapMax ${params.alignMatesGapMax} \\
        --alignSJDBoverhangMin ${params.alignSJDBoverhangMin} \\
        --alignSJoverhangMin ${params.alignSJoverhangMin} \\
        --alignSoftClipAtReferenceEnds ${params.alignSoftClipAtReferenceEnds} \\
        --alignTranscriptsPerReadNmax ${params.alignTranscriptsPerReadNmax} \\
        --chimJunctionOverhangMin ${params.chimJunctionOverhangMin} \\
        --chimOutType Junctions SeparateSAMold \\
        --chimScoreMin ${params.chimScoreMin} \\
        --chimScoreSeparation ${params.chimScoreSeparation} \\
        --chimSegmentMin ${params.chimSegmentMin} \\
        --genomeDir ${star_idx} \\
        --genomeLoad ${params.genomeLoad} \\
        --limitSjdbInsertNsj ${params.limitSjdbInsertNsj} \\
        --outFileNamePrefix mate2/${base}. \\
        --outFilterMatchNminOverLread ${params.outFilterMatchNminOverLread} \\
        --outFilterMismatchNoverLmax ${params.outFilterMismatchNoverLmax} \\
        --outFilterMultimapNmax ${params.outFilterMultimapNmax} \\
        --outFilterMultimapScoreRange ${params.outFilterMultimapScoreRange} \\
        --outFilterScoreMinOverLread ${params.outFilterScoreMinOverLread} \\
        --outFilterType BySJout \\
        --outReadsUnmapped None \\
        --outSAMtype BAM SortedByCoordinate \\
        --outSAMunmapped Within \\
        --outSJfilterOverhangMin ${params.outSJfilterOverhangMin} \\
        ${readFilesCommand} \\
        --readFilesIn ${reads} \\
        --runThreadN ${task.cpus} \\
        --sjdbFileChrStartEnd ${sjdbfile} \\
        --sjdbScore ${params.sjdbScore} \\
        --winAnchorMultimapNmax ${params.winAnchorMultimapNmax}
    """
}

ch_dcc_dirs = dcc_pairs.join(dcc_mate1).join(dcc_mate2)

process DCC{
    tag "${base}"
    label 'py3'
    label 'process_medium'
    publishDir "${params.outdir}/circrna_discovery/DCC/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/DCC/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/DCC/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/DCC/intermediates/${base}/${it}" : null }

    when:
    'dcc' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(pairs), file(mate1), file(mate2) from ch_dcc_dirs
    file(gtf) from ch_gtf
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_dcc.bed") into dcc_results
    tuple val(base), file("${base}") into dcc_intermediates
    tuple val(base), file("${base}.bed") into dcc_annotated
    tuple val(base), file("fasta/*") into dcc_fasta
    tuple val(base), file("${base}.log") into dcc_logs

    script:
    COJ="Chimeric.out.junction"
    """
    sed -i 's/^chr//g' $gtf
    printf "${base}/${base}.${COJ}" > samplesheet
    printf "mate1/${base}.${COJ}" > mate1file
    printf "mate2/${base}.${COJ}" > mate2file
    DCC @samplesheet -mt1 @mate1file -mt2 @mate2file -D -an $gtf -Pi -ss -F -M -Nr 1 1 -fg -A $fasta -N -T ${task.cpus}

    ## Add strand to counts
    awk '{print \$6}' CircCoordinates >> strand
    paste CircRNACount strand | tail -n +2 | awk -v OFS="\t" '{print \$1,\$2,\$3,\$5,\$4}' >> ${base}_dcc.txt

    ## filter reads
    awk '{if(\$5 >= ${params.bsj_reads}) print \$0}' ${base}_dcc.txt > ${base}_dcc.filtered

    ## fix start position (+1)
    awk -v OFS="\t" '{\$2-=1;print}' ${base}_dcc.filtered > ${base}_dcc.bed

    mkdir -p ${base}
    rm strand
    rm ${base}_dcc.txt
    rm ${base}_dcc.filtered
    find . -maxdepth 1 -mindepth 1 -type f -not -name ${base}_dcc.bed -print0 | xargs -0 mv -t ${base}/

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_dcc.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process FIND_ANCHORS{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "{*.*}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/find_circ/intermediates/${base}/${it}" : null }

    when:
    'find_circ' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(fastq) from find_circ_reads
    val(fasta) from ch_fasta
    file(bowtie2_index) from ch_bowtie2_anchors.collect()

    output:
    tuple val(base), file("${base}_anchors.qfa.gz") into ch_anchors
    tuple val(base), file("*.*") into find_anchors_intermediates

    script:
    """
    bowtie2 -p ${task.cpus} --very-sensitive --mm -D 20 --score-min=C,-15,0 \\
    -x ${fasta.baseName} -q -1 ${fastq[0]} -2 ${fastq[1]} \\
    | samtools view -hbuS - | samtools sort --threads ${task.cpus} -m 2G - > ${base}.bam

    samtools view -hf 4 ${base}.bam | samtools view -Sb - > ${base}_unmapped.bam

    unmapped2anchors.py ${base}_unmapped.bam | gzip > ${base}_anchors.qfa.gz
    """
}

process FIND_CIRC{
    tag "${base}"
    label 'process_high'
    publishDir "${params.outdir}/circrna_discovery/find_circ/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/find_circ/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/find_circ/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "*.sites.*",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/find_circ/intermediates/${base}/${it}" : null }

    when:
    'find_circ' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(anchors) from ch_anchors
    val(fasta) from ch_fasta
    file(fai) from ch_fai
    file(bowtie2_index) from ch_bowtie2_find_circ.collect()
    val(fasta_chr_path) from ch_chromosomes
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_find_circ.bed") into find_circ_results
    tuple val(base), file("*.sites.*") into find_circ_intermediates
    tuple val(base), file("${base}.bed") into find_circ_annotated
    tuple val(base), file("fasta/*") into find_circ_fasta
    tuple val(base), file("${base}.log") into find_circ_logs

    script:
    """
    bowtie2 -p ${task.cpus} --reorder --mm -D 20 --score-min=C,-15,0 -q -x ${fasta.baseName} \\
    -U $anchors | python ${projectDir}/bin/find_circ.py -G $fasta_chr_path -p ${base} -s ${base}.sites.log > ${base}.sites.bed 2> ${base}.sites.reads

    ## filtering
    grep circ ${base}.sites.bed | grep -v chrM | python ${projectDir}/bin/sum.py -2,3 | python ${projectDir}/bin/scorethresh.py -16 1 | python ${projectDir}/bin/scorethresh.py -15 2 | python ${projectDir}/bin/scorethresh.py -14 2 | python ${projectDir}/bin/scorethresh.py 7 ${params.bsj_reads} | python ${projectDir}/bin/scorethresh.py 8,9 35 | python ${projectDir}/bin/scorethresh.py -17 100000 >> ${base}.txt

    tail -n +2 ${base}.txt | awk -v OFS="\t" '{print \$1,\$2,\$3,\$6,\$5}' > ${base}_find_circ.bed

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_find_circ.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi ${fasta.baseName}.fa -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process MAPSPLICE_ALIGN{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/MapSplice/intermediates/${it}" : null }

    when:
    'mapsplice' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(fastq) from mapsplice_reads
    val(mapsplice_ref) from ch_chromosomes
    file(bowtie_index) from ch_bowtie.collect()
    file(gtf) from ch_gtf

    output:
    tuple val(base), file("${base}/fusions_raw.txt") into mapsplice_fusion
    tuple val(base), file("${base}") into mapsplice_align_intermediates

    script:
    def prefix = gtf.toString() - ~/.gtf/
    def handleGzip_R1 = fastq[0].toString().endsWith('.gz') ? "gzip -d --force ${fastq[0]}" : ''
    def handleGzip_R2 = fastq[1].toString().endsWith('.gz') ? "gzip -d --force ${fastq[1]}" : ''
    def read1 = fastq[0].toString().endsWith('.gz') ? fastq[0].toString() - ~/.gz/ : fastq[0]
    def read2 = fastq[1].toString().endsWith('.gz') ? fastq[1].toString() - ~/.gz/ : fastq[1]
    """
    $handleGzip_R1
    $handleGzip_R2

    mapsplice.py \\
       -c $mapsplice_ref \\
       -x $prefix \\
       -1 ${read1} \\
       -2 ${read2} \\
       -p ${task.cpus} \\
       --bam \\
       --seglen 25 \\
       --min-intron ${params.alignIntronMin} \\
       --max-intron ${params.alignIntronMax} \\
       --min-map-len 40 \\
       --fusion-non-canonical \\
       --min-fusion-distance 200 \\
       --gene-gtf $gtf \\
       -o $base
   """
}

/*
  STEP 6.7.2: MapSplice quantification
*/

process MAPSPLICE_PARSE{
    tag "${base}"
    label 'process_medium'
    publishDir "${params.outdir}/circrna_discovery/MapSplice/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/MapSplice/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/MapSplice/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}/*",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/MapSplice/intermediates/${it}" : null }

    when:
    'mapsplice' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(raw_fusion) from mapsplice_fusion
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(gene_annotation) from ch_gene
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_mapsplice.bed") into mapsplice_results
    tuple val(base), file("${base}/*") into mapsplice_intermediates
    tuple val(base), file("${base}.bed") into mapsplice_annotated
    tuple val(base), file("fasta/*") into mapsplice_fasta
    tuple val(base), file("${base}.log") into mapsplice_logs

    script:
    """
    mkdir -p ${base}

    CIRCexplorer2 parse -t MapSplice $raw_fusion -b ${base}/${base}.mapsplice.junction.bed

    CIRCexplorer2 annotate -r $gene_annotation -g $fasta -b ${base}/${base}.mapsplice.junction.bed -o ${base}/${base}.txt

    awk '{if(\$13 >= ${params.bsj_reads}) print \$0}' ${base}/${base}.txt | awk -v OFS="\t" '{print \$1,\$2,\$3,\$6,\$13}' > ${base}_mapsplice.bed

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_mapsplice.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

process SEGEMEHL{
    tag "${base}"
    label 'process_high'
    publishDir "${params.outdir}/circrna_discovery/Segemehl/${base}", mode: params.publish_dir_mode, pattern: "${base}.bed"
    publishDir "${params.outdir}/circrna_discovery/Segemehl/${base}", mode: params.publish_dir_mode, pattern: "fasta/*"
    publishDir "${params.outdir}/circrna_discovery/Segemehl/annotation_logs", mode: params.publish_dir_mode, pattern: "${base}.log"
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_quantification_intermediates ? "circrna_discovery/Segemehl/intermediates/${it}" : null }

    when:
    'segemehl' in tool && 'circrna_discovery' in module

    input:
    tuple val(base), file(fastq) from segemehl_reads
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(idx) from ch_segemehl
    file(gtf_filt) from ch_gtf_filtered

    output:
    tuple val(base), file("${base}_segemehl.bed") into segemehl_results
    tuple val(base), file("${base}") into segemehl_intermediates
    tuple val(base), file("${base}.bed") into segemehl_annotated
    tuple val(base), file("fasta/*") into segemehl_fasta
    tuple val(base), file("${base}.log") into segemehl_logs

    script:
    def handleSam = params.save_quantification_intermediates ? "samtools view -hbS ${base}/${base}.sam > ${base}/${base}.bam && rm ${base}/${base}.sam" : "rm -rf ${base}/${base}.sam"
    """
    mkdir -p ${base}

    segemehl.x \\
        -t ${task.cpus} \\
        -d $fasta \\
        -i $idx \\
        -q ${fastq[0]} \\
        -p ${fastq[1]} \\
        -S \\
        -o ${base}/${base}.sam

    $handleSam

    # Segemehl does not preserve strand information, nor account for it
    # when collapsing and counting reads using haarz.x. This is my own fix which does.
    grep ';C;' ${base}/${base}.sngl.bed | awk -v OFS="\t" '{print \$1,\$2,\$3,\$6}' | sort | uniq -c | awk -v OFS="\t" '{print \$2,\$3,\$4,\$5,\$1}' > ${base}/${base}_collapsed.bed

    # now let user filter by BSJ read count param.
    awk -v OFS="\t" -v BSJ=${params.bsj_reads} '{if(\$5>=BSJ) print \$0}' ${base}/${base}_collapsed.bed > ${base}_segemehl.bed

    ## Annotation
    awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, \$5, \$4}' ${base}_segemehl.bed > circs.bed
    bash ${projectDir}/bin/annotate_outputs.sh &> ${base}.log
    mv master_bed12.bed ${base}.bed.tmp

    ## FASTA sequences
    cut -d\$'\t' -f1-12 ${base}.bed.tmp > bed12.tmp
    bedtools getfasta -fi $fasta -bed bed12.tmp -s -split -name > circ_seq.tmp
    ## clean fasta header
    grep -A 1 '>' circ_seq.tmp | cut -d: -f1,2,3 > circ_seq.fa && rm circ_seq.tmp
    ## output to dir
    mkdir -p fasta
    awk -F '>' '/^>/ {F=sprintf("fasta/%s.fa",\$2); print > F;next;} {print >> F;}' < circ_seq.fa
    ## mature spliced len for annotation file
    for f in fasta/*.fa; do grep -v '>' \$f | wc -c ; done &> mature.txt
    paste ${base}.bed.tmp mature.txt > ${base}.bed
    """
}

/*
================================================================================
                         Generate circRNA count matrix
================================================================================
*/

quantification_results = ciriquant_results.mix(circexplorer2_results, circrna_finder_results, dcc_results, find_circ_results, mapsplice_results, segemehl_results)

if(tools_selected > 1){
   process MERGE_TOOLS{
       tag "${base}"

       when:
       'circrna_discovery' in module

       input:
       tuple val(base), file(bed) from quantification_results.groupTuple()

       output:
       file("${base}.bed") into sample_counts

       script:
       """
       ## make list of files for R to read
       ls *.bed > samples.csv

       ## Add catch for empty bed file and delete
       bash ${projectDir}/bin/check_empty.sh

       ## Use intersection of "n" (params.tool_filter) circRNAs called by tools
       ## remove duplicate IDs, keep highest count.
       Rscript ${projectDir}/bin/consolidate_algorithms_intersection.R samples.csv $params.tool_filter

       mv combined_counts.bed ${base}.bed
       """
   }
   process COUNT_MATRIX_COMBINED{
       publishDir "${params.outdir}/circrna_discovery", pattern: "count_matrix.txt", mode: params.publish_dir_mode

       when:
       'circrna_discovery' in module

       input:
       file(bed) from sample_counts.collect()

       output:
       file("circRNA_matrix.txt") into circRNA_counts
       file("count_matrix.txt") into matrix

       script:
       """
       python ${projectDir}/bin/circRNA_counts_matrix.py > circRNA_matrix.txt
       Rscript ${projectDir}/bin/reformat_count_matrix.R
       """
   }
}else{
   process COUNT_MATRIX_SINGLE{
       publishDir "${params.outdir}/circrna_discovery", pattern: "count_matrix.txt", mode: params.publish_dir_mode

       when:
       'circrna_discovery' in module

       input:
       file(bed) from quantification_results.collect()
       val(tool) from params.tool

       output:
       file("circRNA_matrix.txt") into circRNA_counts
       file("count_matrix.txt") into matrix

       script:
       """
       # Strip tool name from BED files (no consolidation prior to this step for 1 tool)
       for b in *.bed; do
           basename=\${b%".bed"};
           sample_name=\${basename%"_${tool}"};
           mv \$b \${sample_name}.bed
       done

       python ${projectDir}/bin/circRNA_counts_matrix.py > circRNA_matrix.txt
       Rscript ${projectDir}/bin/reformat_count_matrix.R
       """
    }
}

/*
================================================================================
                             miRNA Prediction
================================================================================
*/

process TARGETSCAN_DATABASE{
    when:
    'mirna_prediction' in module

    input:
    file(mature) from ch_mature

    output:
    file("mature.txt") into ch_mature_txt

    script:
    """
    bash ${projectDir}/bin/targetscan_format.sh $mature
    """
}

mirna_input = ciriquant_fasta.mix(circexplorer2_fasta, circrna_finder_fasta, dcc_fasta, mapsplice_fasta, find_circ_fasta, segemehl_fasta).unique().transpose()

process MIRNA_PREDICTION{
    tag "${base}"
    label 'process_low'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "*.miRanda.txt",
        saveAs: { params.save_mirna_predictions ? "mirna_prediction/miRanda/${base}/${it}" : null }
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "*.targetscan.txt",
        saveAs: { params.save_mirna_predictions ? "mirna_prediction/TargetScan/${base}/${it}" : null }
    when:
    'mirna_prediction' in module

    input:
    tuple val(base), file(fasta) from mirna_input
    file(mirbase) from ch_mature
    file(mirbase_txt) from ch_mature_txt

    output:
    tuple val(base), file("*.miRanda.txt"), file("*.targetscan.txt") into mirna_prediction

    script:
    prefix = fasta.toString() - ~/.fa/
    """
    miranda $mirbase $fasta -strict -out ${prefix}.bindsites.out -quiet
    echo "miRNA Target Score Energy_KcalMol Query_Start Query_End Subject_Start Subject_End Aln_len Subject_Identity Query_Identity" | tr ' ' '\t' > ${prefix}.miRanda.txt

    # Add catch here for non hits (supply NAs to outfile)
    # Making the decision that if miRanda fails, then the miRNA analysis for this circRNA exits cleanly.
    # Happy to rework in the future, but do not want pipeline failing on low confidence circRNA calls.
    ## exit code 1 = fail, 0 = success
    if grep -A 1 -q "Scores for this hit:" ${prefix}.bindsites.out;
    then
        grep -A 1 "Scores for this hit:" ${prefix}.bindsites.out | sort | grep ">" | cut -c 2- | tr ' ' '\t' >> ${prefix}.miRanda.txt

        ##format for targetscan
        cat $fasta | grep ">" | sed 's/>//g' > id
        cat $fasta | grep -v ">" > seq
        echo "0000" > species
        paste id species seq > ${prefix}_ts.txt

        # run targetscan
        targetscan_70.pl mature.txt ${prefix}_ts.txt ${prefix}.targetscan.txt
    else
        ## Add NA's to miRanda cols:
        printf "%0.sNA\t" {1..11} >> ${prefix}.miRanda.txt
        ## Construct TargetScan header
        echo "a_Gene_ID miRNA_family_ID species_ID MSA_start MSA_end UTR_start UTR_end Group_num Site_type miRNA_in_this_species Group_type Species_in_this_group Species_in_this_group_with_this_site_type ORF_overlap" | tr ' ' '\t' > ${prefix}.targetscan.txt
        ## Add NA's to file
        printf "%0.sNA\t" {1..13} >> ${prefix}.targetscan.txt
    fi
    """
}

process MIRNA_TARGETS{
    tag "${base}"
    label 'process_low'
    publishDir "${params.outdir}/mirna_prediction/${base}", mode: params.publish_dir_mode, pattern: "*miRNA_targets.txt"
    publishDir "${params.outdir}/mirna_prediction/${base}/pdf", mode: params.publish_dir_mode, pattern: "*.pdf"

    input:
    tuple val(base), file(miranda), file(targetscan) from mirna_prediction
    file(fasta) from ch_fasta
    file(fai) from ch_fai
    file(filt_gtf) from ch_gtf_filtered
    val(species) from ch_species

    output:
    tuple val(base), file("*.pdf") into circos_plots
    tuple val(base), file("*miRNA_targets.txt") into circrna_mirna_targets

    script:
    def species_id = species + "-"
    """
    ## As before, we have a catch for NA miRNA pred files.
    grep -v "miRNA" $miranda | if grep -q "NA";
    then
        touch ${base}_fail_catch_miRNA_targets.txt
        touch ${base}_fail_catch.pdf
    else
        ## use file name to derive bed12 coordiantes.
        echo *.miRanda.txt | sed -E 's/^(chr[^:]+):([0-9]+)-([0-9]+):([^.]+).*/\\1\\t\\2\\t\\3\\t\\4/' | awk -v OFS="\t" '{print \$1, \$2, \$3, \$1":"\$2"-"\$3":"\$4, "0", \$4}' > circs.bed
        bash ${projectDir}/bin/annotate_outputs.sh &> circ.log
        mv master_bed12.bed circ.bed.tmp

        ## Prep exon track for circlize
        cut -d\$'\t' -f1-12 circ.bed.tmp > bed12.tmp
        bash ${projectDir}/bin/prep_circos.sh bed12.tmp

        ## add mature spl len (+ 1 bp)
        awk '{print \$11}' circ.bed.tmp | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\\n", \$i}' | awk 'BEGIN {total=0} {total += \$1} END {print total + 1}' > ml
        paste circ.bed.tmp ml > circ.bed

        Rscript ${projectDir}/bin/mirna_circos.R circ.bed $miranda $targetscan circlize_exons.txt $species_id
    fi
    """
}

/*
================================================================================
                            Differential Expression
================================================================================
*/

ch_hisat_index_files = params.hisat ? Channel.value(file("${params.hisat}/*")) :  hisat_built

process HISAT_ALIGN{
    tag "${base}"
    label 'process_high'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}.bam",
        saveAs: { params.save_rnaseq_intermediates ? "differential_expression/intermediates/Hisat2/${it}" : null }

    when:
    'differential_expression' in module

    input:
    tuple val(base), file(fastq) from hisat_reads
    file(hisat2_index) from ch_hisat_index_files.collect()
    file(fasta) from ch_fasta

    output:
    tuple val(base), file("${base}.bam") into hisat_bam

    script:
    """
    hisat2 -p ${task.cpus} --dta -q -x ${fasta.baseName} -1 ${fastq[0]} -2 ${fastq[1]} -t | samtools view -bS - | samtools sort --threads ${task.cpus} -m 2G - > ${base}.bam
    """
}

process STRINGTIE{
    tag "${base}"
    label 'process_medium'
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "${base}",
        saveAs: { params.save_rnaseq_intermediates ? "differential_expression/intermediates/StringTie/${it}" : null }

    when:
    'differential_expression' in module

    input:
    tuple val(base), file(bam) from hisat_bam
    file(gtf) from ch_gtf

    output:
    file("${base}") into stringtie_dir

    script:
    """
    mkdir ${base}/
    stringtie $bam -e -G $gtf -C ${base}/${base}_cov.gtf -p ${task.cpus} -o ${base}/${base}.gtf -A ${base}/${base}_genes.list
    """
}

process DEA{
    label 'process_medium'
    publishDir "${params.outdir}/differential_expression", pattern: "circRNA", mode: params.publish_dir_mode
    publishDir "${params.outdir}/differential_expression", pattern: "boxplots", mode: params.publish_dir_mode
    publishDir "${params.outdir}/quality_control", pattern: "DESeq2_QC", mode: params.publish_dir_mode
    publishDir params.outdir, mode: params.publish_dir_mode, pattern: "RNA-Seq",
        saveAs: { params.save_rnaseq_intermediates ? "differential_expression/intermediates/${it}" : null }

    when:
    'differential_expression' in module

    input:
    file(gtf_dir) from stringtie_dir.collect()
    file(circ_matrix) from circRNA_counts
    file(phenotype) from ch_phenotype
    val(species) from ch_species

    output:
    file("RNA-Seq") into rnaseq_dir
    file("circRNA") into circrna_dir
    file("boxplots") into boxplots_dir
    file("DESeq2_QC") into qc_plots

    script:
    """
    for i in \$(ls -d */); do sample=\${i%"/"}; file=\${sample}.gtf; touch samples.txt; printf "\$sample\t\${i}\${file}\n" >> samples.txt; done

    prepDE.py -i samples.txt

    Rscript ${projectDir}/bin/DEA.R gene_count_matrix.csv $phenotype $circ_matrix $species ${projectDir}/bin/ensemblDatabase_map.txt

    mv gene_count_matrix.csv RNA-Seq
    mv transcript_count_matrix.csv RNA-Seq
    """
}



/*
================================================================================
                           Auxiliary functions
================================================================================
*/

// Check integer
def isValidInteger(value){
    value instanceof Integer
}

// Check parameter existence
def checkParameterExistence(it, list) {
    if (!list.contains(it)) {
        log.warn "Unknown parameter: ${it}"
        return false
    }
    return true
}

// Compare each parameter with a list of parameters
def checkParameterList(list, realList) {
    return list.every{ checkParameterExistence(it, realList) }
}

// Define list of available tools
def defineToolList() {
    return [
        'ciriquant',
        'circexplorer2',
        'find_circ',
        'circrna_finder',
        'dcc',
        'mapsplice',
        'segemehl'
        ]
}

// Define module list
def defineModuleList() {
    return [
    'circrna_discovery',
    'mirna_prediction',
    'differential_expression'
    ]
}

// Check if a row has the expected number of item
def checkNumberOfItem(row, number) {
    if (row.size() != number) exit 1, "[nf-core/circrna] error:  Invalid CSV input - malformed row (e.g. missing column) in ${row}, see '--help' flag and documentation under 'running the pipeline' for more information"
    return true
}

// Return file if it exists
def return_file(it) {
    if (!file(it).exists()) exit 1, "[nf-core/circrna] error: Cannot find supplied FASTQ or BAM input file. If using input method CSV set to NA if no file required. See '--help' flag and documentation under 'running the pipeline' for more information. Check file: ${it}"
    return file(it)
}

// Check file extension
def has_extension(it, extension) {
    it.toString().toLowerCase().endsWith(extension.toLowerCase())
}

// Read input files from input CSV
def extract_data(csvFile){
    Channel
        .fromPath(csvFile)
        .splitCsv(header: true, sep: ',')
        .map{ row ->

        def expected_keys = ["Sample_ID", "Read1", "Read2", "Bam"]
        if(!row.keySet().containsAll(expected_keys)) exit 1, "[nf-core/circrna] error: Invalid CSV input - malformed column names. Please use the column names 'Sample_ID', 'Read1', 'Read2', 'Bam'."

        checkNumberOfItem(row, 4)

        def samples = row.Sample_ID
        def read1 = row.Read1.matches('NA') ? 'NA' : return_file(row.Read1)
        def read2 = row.Read2.matches('NA') ? 'NA' : return_file(row.Read2)
        def bam = row.Bam.matches('NA') ? 'NA' : return_file(row.Bam)

        if(samples == '' || read1 == '' || read2 == '' || bam == '') exit 1, "[nf-core/circrna] error: a field does not contain any information. Please check your CSV file"
        if(read1.matches('NA') && read2.matches('NA') && bam.matches('NA')) exit 1, "[nf-core/circrna] error: A row in your CSV file appears to have missing information."
        if( !read1.matches('NA') && !has_extension(read1, "fastq.gz") && !has_extension(read1, "fq.gz") && !has_extension(read1, "fastq") && !has_extension(read1, "fq")) exit 1, "[nf-core/circrna] error: A specified R1 file either has a non-recognizable FASTQ extension or is not NA. See '--help' flag and documentation under 'running the pipeline' for more information. Check: ${r1}"
        if( !read2.matches('NA') && !has_extension(read2, "fastq.gz") && !has_extension(read2, "fq.gz") && !has_extension(read2, "fastq") && !has_extension(read2, "fq")) exit 1, "[nf-core/circrna] error: A specified R2 file either has a non-recognizable FASTQ extension or is not NA. See '--help' flag and documentation under 'running the pipeline' for more information. Check: ${r2}"
        if( !bam.matches('NA') && !has_extension(bam, "bam")) exit 1, "[nf-core/eager] error: A specified BAM file either has a non-recognizable extension or is not NA. See '--help' flag and documentation under 'running the pipeline' for more information. Check: ${bam}"

        // output tuple mimicking fromFilePairs if FASTQ provided, else tuple for BAM
        if(bam.matches('NA')){
           [ samples, [read1, read2] ]
        }else{
           [ samples, bam ]
        }

        }
}

// If no input CSV provided, parse input directory containing files.
def retrieve_input_paths(input, type){

      if(type == 'fastq'){

         fastq_files = input
         Channel
               .fromFilePairs(fastq_files)
               .filter { it =~/.*.fastq.gz|.*.fq.gz|.*.fastq|.*.fq/ }
               .ifEmpty{exit 1, "[nf-core/circrna] error: Your FASTQ files do not have the appropriate extension of either '.fastq.gz', '.fq.gz', .fastq' or '.fq'."}
               .map{ row -> [ row[0], [ row[1][0], row[1][1] ]]}
               .ifEmpty{exit 1, "[nf-core/circrna] error: --input was empty - no files supplied"}
               .set{reads_for_csv}

      }else if(type == 'bam'){

         bam_files = input
         Channel
               .fromFilePairs(bam_files, size: 1)
               .filter{ it =~/.*.bam/}
               .map{ row -> [row[0], [row[1][0]]]}
               .ifEmpty{exit 1, "[nf-core/circrna] error: Cannot find bam file matching: ${bam_files}"}
               .set{reads_for_csv}
      }

      reads_for_csv
                  .map{

                  def samples = it[0]
                  def read1 = (type == 'bam') ? 'NA' : return_file(it[1][0])
                  def read2 = (type == 'bam') ? 'NA' : return_file(it[1][1])
                  def bam =   (type == 'fastq') ? 'NA' : return_file(it[1][0])

                  if(bam.matches('NA')){
                     [ samples, [read1, read2] ]
                  }else{
                     [ samples, bam ]
                  }

                  }
                .ifEmpty{exit 1, "[nf-core/circrna] error: Invalid file paths with --input"}
}


// Check input phenotype file

def examine_phenotype(pheno){

  Channel
        .fromPath(pheno)
        .splitCsv(header: true, sep: ',')
        .map{ row ->

        def expected_cols = ['condition']

        if (!row.keySet().containsAll(expected_cols)) exit 1, "[nf-core/circrna] error: 'condition' is not a column name in the phenotype file.\n\nThe response variable must be named 'condition', please refer to the usage documentation online"

        def condition  = row.condition.matches('NA') ? 'NA' : row.condition

        if(condition == '') exit 1, "[nf-core/circrna] error: Invalid phenotype file, condition column contains empty cells."
        if(condition.matches('NA')) exit 1, "[nf-core/circrna] error: NA value in phenotype condition column."

        }
        .toList()

        return Channel.value(file(pheno))
}

/*
================================================================================
                           nf-core functions
================================================================================
*/

workflow.onError {
    // Print unexpected parameters - easiest is to just rerun validation
    NfcoreSchema.validateParameters(params, json_schema, log)
}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/circrna v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

// handle multiqc_channels
//if(params.trim_fastq == false){
//    ch_multiqc_report = multiqc_trim_out
//}else{
//    ch_multiqc_report = multiqc_raw_out
//}

// Completion e-mail notification
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/circrna] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/circrna] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/circrna] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/circrna] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, projectDir: "$projectDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$projectDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/circrna] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/circrna] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green  = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red    = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset  = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/circrna]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/circrna]${c_red} Pipeline completed with errors${c_reset}-"
    }
}



def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = 'hostname'.execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "${c_red}====================================================${c_reset}\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "${c_red}====================================================${c_reset}\n"
                }
            }
        }
    }
}
