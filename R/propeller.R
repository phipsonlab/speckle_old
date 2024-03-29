#' Finding statistically significant differences in cell type proportions
#'
#' Calculates cell type proportions, performs a variance stabilising
#' transformation on the proportions and determines whether the cell type
#' proportions are statistically significant between different groups using
#' linear modelling.
#'
#' This function will take a \code{SingleCellExperiment} or \code{Seurat}
#' object and extract the \code{group}, \code{sample} and \code{clusters} cell
#' information. The user can either state these factor vectors explicitly in
#' the call to the \code{propeller} function, or internal functions will
#' extract them from the relevants objects. The user must ensure that
#' \code{group} and \code{sample} are columns in the metadata assays of the
#' relevant objects (any combination of upper/lower case is acceptable). For
#' \code{Seurat} objects the clusters are extracted using the \code{Idents}
#' function. For \code{SingleCellExperiment} objects, \code{clusters} needs to
#' be a column in the \code{colData} assay.
#'
#' The \code{propeller} function calculates cell type proportions for each
#' biological replicate, performs a variance stabilising transformation on the
#' matrix of proportions and fits a linear model for each cell type or cluster
#' using the \code{limma} framework. There are two options for the 
#' transformation: arcsin square root or logit. Propeller tests whether there 
#' is a difference in the cell type proportions between multiple groups. 
#' If there are only 2 groups, a t-test is used to calculate p-values, and if 
#' there are more than 2 groups, an F-test (ANOVA) is used. Cell type 
#' proportions of 1 or 0 are accommodated. Benjamini and Hochberg false 
#' discovery rates are calculated to account to multiple testing of 
#' cell types/clusters.
#'
#' @aliases propeller
#' @param x object of class \code{SingleCellExperiment} or \code{Seurat}
#' @param clusters a factor specifying the cluster or cell type for every cell.
#' For \code{SingleCellExperiment} objects this should correspond to a column
#' called \code{clusters} in the \code{colData} assay. For \code{Seurat}
#' objects this will be extracted by a call to \code{Idents(x)}.
#' @param sample a factor specifying the biological replicate for each cell.
#' For \code{SingleCellExperiment} objects this should correspond to a column
#' called \code{sample} in the \code{colData} assay and for \code{Seurat}
#' objects this should correspond to \code{x$sample}.
#' @param group a factor specifying the groups of interest for performing the
#' differential proportions analysis. For \code{SingleCellExperiment} objects
#' this should correspond to a column called \code{group} in the \code{colData}
#' assay.  For \code{Seurat} objects this should correspond to \code{x$group}.
#' @param trend logical, if true fits a mean variance trend on the transformed
#' proportions
#' @param robust logical, if true performs robust empirical Bayes shrinkage of
#' the variances
#' @param transform a character scalar specifying which transformation of the 
#' proportions to perform. Possible values include "asin" or "logit". Defaults
#' to "logit".
#'
#' @return produces a dataframe of results
#'
#' @importFrom stats p.adjust
#' @export propeller
#'
#' @author Belinda Phipson
#'
#' @seealso \code{\link{propeller.ttest}} \code{\link{propeller.anova}} 
#' \code{\link{lmFit}}, \code{\link{eBayes}},
#' \code{\link{getTransformedProps}}
#'
#' @references Smyth, G.K. (2004). Linear models and empirical Bayes methods
#' for assessing differential expression in microarray experiments.
#' \emph{Statistical Applications in Genetics and Molecular Biology}, Volume
#' \bold{3}, Article 3.
#'
#' Benjamini, Y., and Hochberg, Y. (1995). Controlling the false discovery
#' rate: a practical and powerful approach to multiple testing. \emph{Journal
#' of the Royal Statistical Society Series}, B, \bold{57}, 289-300.
#'
#' @examples
#'
#'   library(speckle)
#'   library(ggplot2)
#'   library(limma)
#'
#'   # Make up some data
#'   # True cell type proportions for 4 samples
#'   p_s1 <- c(0.5,0.3,0.2)
#'   p_s2 <- c(0.6,0.3,0.1)
#'   p_s3 <- c(0.3,0.4,0.3)
#'   p_s4 <- c(0.4,0.3,0.3)
#'
#'   # Total numbers of cells per sample
#'   numcells <- c(1000,1500,900,1200)
#'
#'   # Generate cell-level vector for sample info
#'   biorep <- rep(c("s1","s2","s3","s4"),numcells)
#'   length(biorep)
#'
#'   # Numbers of cells for each of the 3 clusters per sample
#'   n_s1 <- p_s1*numcells[1]
#'   n_s2 <- p_s2*numcells[2]
#'   n_s3 <- p_s3*numcells[3]
#'   n_s4 <- p_s4*numcells[4]
#'
#'   # Assign cluster labels for 4 samples
#'   cl_s1 <- rep(c("c0","c1","c2"),n_s1)
#'   cl_s2 <- rep(c("c0","c1","c2"),n_s2)
#'   cl_s3 <- rep(c("c0","c1","c2"),n_s3)
#'   cl_s4 <- rep(c("c0","c1","c2"),n_s4)
#'
#'   # Generate cell-level vector for cluster info
#'   clust <- c(cl_s1,cl_s2,cl_s3,cl_s4)
#'   length(clust)
#'
#'   # Assume s1 and s2 belong to group 1 and s3 and s4 belong to group 2
#'   grp <- rep(c("grp1","grp2"),c(sum(numcells[1:2]),sum(numcells[3:4])))
#'
#'   propeller(clusters = clust, sample = biorep, group = grp,
#'   robust = FALSE, trend = FALSE, transform="asin")
#'
propeller <- function(x=NULL, clusters=NULL, sample=NULL, group=NULL,
                        trend=FALSE, robust=TRUE, transform="logit")
#    Testing for differences in cell type proportions
#    Belinda Phipson
#    29 July 2019
#    Modified 22 April 2020
{

    if(is.null(x) & is.null(sample) & is.null(group) & is.null(clusters))
        stop("Please provide either a SingleCellExperiment object or Seurat
        object with required annotation metadata, or explicitly provide
        clusters, sample and group information")

    if((is.null(clusters) | is.null(sample) | is.null(group)) & !is.null(x)){
        # Extract cluster, sample and group info from SCE object
        if(is(x,"SingleCellExperiment"))
            y <- .extractSCE(x)

        # Extract cluster, sample and group info from Seurat object
        if(is(x,"Seurat"))
            y <- .extractSeurat(x)

        clusters <- y$clusters
        sample <- y$sample
        group <- y$group
    }
    
    if(is.null(transform)) transform <- "logit"

    # Get transformed proportions
    prop.list <- getTransformedProps(clusters, sample, transform)

    # Calculate baseline proportions for each cluster
    baseline.props <- table(clusters)/sum(table(clusters))

    # Collapse group information
    group.coll <- table(sample, group)

    design <- matrix(as.integer(group.coll != 0), ncol=ncol(group.coll))
    colnames(design) <- colnames(group.coll)

    if(ncol(design)==2){
        message("group variable has 2 levels, t-tests will be performed")
        contrasts <- c(1,-1)
        out <- propeller.ttest(prop.list, design, contrasts=contrasts,
                                robust=robust, trend=trend, sort=FALSE)
        out <- data.frame(BaselineProp=baseline.props,out)
        out[order(out$P.Value),]
    }
    else if(ncol(design)>=2){
        message("group variable has > 2 levels, ANOVA will be performed")
        coef <- seq_len(ncol(design))
        out <- propeller.anova(prop.list, design, coef=coef, robust=robust,
                                trend=trend, sort=FALSE)
        out <- data.frame(BaselineProp=as.vector(baseline.props),out)
        out[order(out$P.Value),]
    }

}

#' Extract metadata from \code{SingleCellExperiment} object
#'
#' This is an accessor function that extracts cluster, sample and group
#' information for each cell.
#'
#' @param x object of class \code{SingleCellExperiment}
#'
#' @return a dataframe containing clusters, sample and group
#'
#' @importFrom methods is
#' @importFrom SingleCellExperiment colData
#'
#' @author Belinda Phipson
#'
.extractSCE <- function(x){
    message("extracting sample information from SingleCellExperiment object")
    colnames(colData(x)) <- toupper(colnames(colData(x)))
    clusters <- factor(colData(x)$CLUSTER)
    sample <- factor(colData(x)$SAMPLE)
    group <- factor(colData(x)$GROUP)
    data.frame(clusters=clusters,sample=sample,group=group)
}

#' Extract metadata from \code{Seurat} object
#'
#' This is an accessor function that extracts cluster, sample and group
#' information for each cell.
#'
#' @param x object of class \code{Seurat}
#'
#' @return a dataframe containing clusters, sample and group
#'
#' @importFrom Seurat Idents
#'
#' @author Belinda Phipson
#'
.extractSeurat <- function(x){
    message("extracting sample information from Seurat object")
    colnames(x@meta.data) <- toupper(colnames(x@meta.data))
    clusters <- factor(Idents(x))
    sample <- factor(x$SAMPLE)
    group <- factor(x$GROUP)
    data.frame(clusters=clusters,sample=sample,group=group)
}



