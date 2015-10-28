#CODE TO RUN PHAST AND RELATED ANALYSIS
#MOSTLY RUN INTERACTIVELY ON A LARGE MEMORY MACHINE, SO FEW SLURM SCRIPT

### GETTING NEUTRAL MODELS ###

#Step 1. Make tree
halStats --tree /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal > tree1.nh
perl -p -i -e 's/Anc\d+//g' tree1.nh 
nw_topology tree1.nh > ratiteTree.nh
nw_labels ratiteTree.nh > species_list

#resolving bifurcations:
#1: reptiles -- turtles as outgroup to archosaurs, gharial + crocs --> croc genome paper
#2: palaeognaths -- several options in different trees
#3: passerines -- ground tit as outgroup to other passerines per Alison's UCE tree
#4: accept Afroaves to resolve landbird polytomy
#5: accept Columbea as sister to passera
#6: balReg + chaVoc = clade (Gruimorphae)
#7: accept Otidae as outgroup to other Passera
#8: Gruimorphae outgroup to waterbirds + landbirds

#now rheas
#ver1 = UCE tree (rheas + tinamous)
#ver2 = Mitchell tree (rheas outgroup to non-ostrichs)
#ver3 = rheas + ECK clade

#Step 2. Get 4-fold degenerate sites based on galGal4 NCBI annotations
#convert to GTF
module load cufflinks
gffread --no-pseudo -C -T -o galGal4.gtf GCF_000002315.3_Gallus_gallus-4.0_genomic.gff 
grep -v "^NC_001323.1" galGal4.gtf | grep "protein_coding" | grep -P "\tCDS\t" > galGal4_filt.gtf

#convert to genepred
gtfToGenePred galGal4_filt.gtf galGal4.gp

#convert to bed
genePredToBed galGal4.gp galGal4.bed

#extract 4D sites
hal4dExtract --conserved --inMemory /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal galGal galGal4.bed galGal4_4d.bed

#not going to use the wrapper scripts as they seem to do odd things. So let's first get a chicken-referenced MAF
mkdir extract_maf
cd extract_maf
cp ../galGal4_4d.bed .
hal2mafMP.py --numProc 48 --splitBySequence --refGenome galGal --noAncestors --noDupes --refTargets galGal4_4d.bed /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal neut4d_input_galGal_ref_ver09222015.maf

#get scaffold list to check that process works
cut -f1,1 galGal4_4d.bed | sort | uniq > galGal_scaffold_list
ls extract_maf/*.maf | wc -l

#fix MAF with sed 
#run the big scaffolds in parallel
for MAF in $(ls extract_maf/*NC*.maf);
do
	sed -i -e 2d $MAF &
done

#run the small scaffolds in serial
for MAF in $(ls extract_maf/*NW*.maf);
do
	sed -i -e 2d $MAF
done

#merge MAFs and make SS file
SPECIES=$(nw_labels ratiteTree.nh | sort | tr '\n' ',')
MSAFILES=$(ls extract_maf/*.maf)
msa_view --aggregate ${SPECIES%?} --in-format MAF --out-format SS --unordered-ss $MSAFILES > neut4d_input.ss

#neut4d_input.ss is now an SS-format alignment of all 4d sites in the original alignment

#Step 3. phyloFit
#want to be sure the neutral models are reliable, so run with --init-random, start 5 independent runs of each model (15 total)
#code to run random iterations:

for ITER in 1 2 3 4 5
do
	phyloFit --tree ratiteTree.ver1.nh --init-random --subst-mod SSREV --out-root neut_ver1_${ITER} --msa-format SS --sym-freqs --log phyloFit_ver1_${ITER}.log neut4d_input.ss &> phyloFit_ver1_${ITER}.out &
	phyloFit --tree ratiteTree.ver2.nh --init-random --subst-mod SSREV --out-root neut_ver2_${ITER} --msa-format SS --sym-freqs --log phyloFit_ver2_${ITER}.log neut4d_input.ss &> phyloFit_ver2_${ITER}.out &
	phyloFit --tree ratiteTree.ver3.nh --init-random --subst-mod SSREV --out-root neut_ver3_${ITER} --msa-format SS --sym-freqs --log phyloFit_ver3_${ITER}.log neut4d_input.ss &> phyloFit_ver3_${ITER}.out &
done

#finally, improve all random models to guarantee convergence
for MOD in $(ls neut*.mod);
do
	NEWMOD=${MOD%%.*}
	phyloFit --init-model $MOD --out-root ${NEWMOD}_update --msa-format SS --sym-freqs --log ${MOD}_update.log neut4d_input.ss &> ${MOD}_update.out &
done

#verify convergence of models
#copy each version to _final.mod

cp neut_ver1_1_update.mod neut_ver1_final.mod
cp neut_ver2_2_update.mod neut_ver2_final.mod
cp neut_ver3_2_update.mod neut_ver3_final.mod

#Step 4. Adjust background GC content to be reflective of the average GC content across the non-ancestral genomes in the alignment
###code added to get GC content for each genome, by sampling every 100 bp
mkdir -p baseComp
cd baseComp
for TARGET in $(halStats --genomes /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal)
do
	#output is fraction_of_As fraction_of_Gs fraction_of_Cs fraction_of_Ts
	halStats --baseComp $TARGET,100 /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal > $TARGET.basecomp
done
cd ..

#get average gc content in non-ancestral genomes and update models:
GC=$(cat /n/regal/edwards_lab/ratites/phast/baseComp/??????.basecomp | awk '{SUM+=$2;SUM+=$3;print SUM/42}' | tail -n 1)
for VER in 1 2 3;
do
	modFreqs neut_ver${VER}_final.mod $GC > neut_ver${VER}_corrected.mod
done

#name all ancestral nodes in the tree model
for MOD in 1 2 3
do
	tree_doctor --name-ancestors neut_ver${MOD}_corrected.mod > neut_ver${MOD}_final.named.mod 
done


### RUN PHYLOP ##
#run halPhyloPMP.py with 12 processors per on each neutral version
#use the _corrected version of each model
for VER in 1 2 3;
do
	mkdir neut_ver$VER
	cp neut_ver${VER}_corrected.mod neut_ver$VER
	cd neut_ver$VER
	halPhyloPMP.py --numProc 12 /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal galGal neut_ver${VER}_corrected.mod galGal_phyloP_ver$VER.wig &> halPhyloP_galGal.log &
	cd ..
done

#also run with ostrich reference
for VER in 1 2 3;
do
	cd neut_ver$VER
	halPhyloPMP.py --numProc 12 /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal strCam neut_ver${VER}_corrected.mod strCam_phyloP_ver$VER.wig &> halPhyloP_strCam.log &
	cd ..
done

#finally also run tree version
for VER in 1 2 3 
do
	cd neut_ver$VER
	halTreePhyloP.py --numProc 24 /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal neut_ver${VER}_corrected.mod . &> halTreePhyloP.log &
	cd ..
done

##RUN CODE (SEPARATE SCRIPT, R & BASH) TO VERIFY THAT THERE IS NO EFFECTIVE DIFFERENCE BETWEEN THE THREE RHEA PLACEMENTS IN PHYLOP SCORES

### RUNNING PHASTCONS ###
#to run phastCons, we need to take a slightly different approach as there is no direct interface with hal
#so the first step is to export the MAFs that we want, in this case starting with two: chicken, ostrich
#for each MAF, we then run phastCons
#sources: https://genome.ucsc.edu/cgi-bin/hgTrackUi?db=hg38&g=cons100way and http://compgen.cshl.edu/phast/phastCons-HOWTO.html
for TARGET in galGal strCam
do
	mkdir -p $TARGET
	cd $TARGET
	hal2mafMP.py --numProc 36 --splitBySequence --sliceSize 5000000 --smallSize 500000 --refGenome $TARGET --noAncestors /n/regal/edwards_lab/ratites/wga/ratite_final_20150627/ratiteAlign.hal ${TARGET}_ref.maf &
	cd ..
done

#fix MAFs
for MAF in $(ls galGal_ref*.maf);
do
	sed -i -e 2d $MAF &
done

#filter duplicates using mafTools
#first step -- remove chicken lines that are from scaffolds other than target with perl script
#second step -- filter with mafDuplicateFilter
for MAF in $(ls galGal_ref_NC*.maf);
do
	./keep_ref_only.pl $MAF &
done

for MAF in $(ls galGal_ref_NC*.temp.maf);
do
	mafDuplicateFilter --maf ${MAF%.temp.maf}.temp.maf > ${MAF%.maf}.pruned.maf &
done


#the output MAFs from mafDuplicateFilter do not guarantee correct strand or order, particularly for galGal specific duplications
#the following code updates / fixes that, first by correcting strand and then order
for MAF in $(ls galGal_ref_NC*.temp.pruned.maf);
do
	mafStrander --maf $MAF --seq galGal --strand + > ${MAF%.pruned.maf}.strand.maf &
done

#finally, we sort the MAF
for FILE in $(ls galGal_ref_NC*.temp.strand.maf);
do
	CHR1=${FILE#galGal_ref_}
	CHR=${CHR1%.temp.strand.maf}
	echo "Processing $CHR"
	mafSorter --maf $FILE --seq galGal.$CHR > $CHR.final.maf &
done

#get rid of temp mafs
rm *.temp*.maf

#split reference into separate files for each chr with samtools
samtools faidx galGal.fa
for FILE in *.final.maf
do
	CHR=${FILE%.final.maf}
	samtools faidx galGal.fa $CHR > $CHR.fa &
done

#Split alignments into chunks
mkdir -p chunks            # put fragments here
for FILE in *.final.maf
do
	CHR=${FILE%.final.maf}
	msa_split $FILE --in-format MAF --refseq $CHR.fa --windows 1000000,0 --out-root chunks/$CHR --out-format SS --min-informative 1000 --between-blocks 5000 2> $CHR.split.log &
done

#Next -- estimate rho for (a subset of) alignments
#This will be done with slurm, processing batches of 10 alignments each

#set up job array input
mkdir -p rho
cd rho
ls ../chunks > files
split -a 3 -d -l 10 files part. #make file parts
sbatch est_rho.sh

#run local rerun
./est_rho_local.sh

#kill processes that have not converged after 2 days
#Next -- average rho to get a global rho estimate

ls mods/*.cons.mod > cons.txt
phyloBoot --read-mods '*cons.txt' --output-average ave.cons.mod 
ls mods/*.noncons.mod > noncons.txt
phyloBoot --read-mods '*noncons.txt' --output-average ave.noncons.mod 

#Next -- run phastCons to predict conserved elements on each target segment
sbatch run_phastCons.sh


#Next -- merge predictions and estimate coverage, look at length, other tuning measures
#Next -- iterate until things look good
#Next -- run final predictions using fixed values for rho, coverage, length in all reference species, but also outputting per base estimates

## TESTS FOR RATITE-SPECIFIC ACCELERATION, ETC ##
#this is a preliminary test based on phyloP and the galGal3->galGal4 CNEEs from the feather paper
#the idea is to test whether the 'named branches' in this case the ratites are accelerated or conserved relative to background
#as a null, run the same test on the tinamou clade
#do this as a job array using the same framework as est_rho.sh

#need to convert chr coordinates in LoweCNEEs.galGal4.bed to NCBI accessions
./replace_chrs.pl LoweCNEEs.galGal4.bed
sbatch est_accel.sh


#clean up 
#phyloP has a bug / issue with bed files with multiple chromosomes in them, it does not do any kind of sensible filtering
#so for each file, need to parse only the lines that match file name
#note also that because this was run on split data, there are a few CNEEs that fall into multiple MAFs and are thus duplicated
for CHR in $(tail -n +2 galGal4.chr2acc | cut -f2,2)
do
	cat ratite/$CHR* | grep "^$CHR" >> ratite_accel.final.out
	cat tinamou/$CHR* | grep "^$CHR" >> tinamou_accel.final.out
done

#replace 0s in pval column with 1e-05 or -1e-05
perl -p -i -e 's/0.00000$/0.00001/' ratite_accel.final.out
perl -p -i -e 's/0.00000$/0.00001/' tinamou_accel.final.out
