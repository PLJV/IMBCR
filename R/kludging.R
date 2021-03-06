# Author: Kyle Taylor <kyle.taylor@pljv.org>
# Year : 2017
# Description : various tasks related to formatting and parsing raw IMBCR data
# into Spatial* and Unmarked* objects.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

#
# Define some useful local functions for manipulating IMBCR data
#
#' hidden function that greps for four-letter-codes
birdcode_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^bird")])
}
#' hidden function that greps for four-letter-codes
commonname_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^c.*.[.]n.*.")])
}
#' hidden function that greps for the distance field name
distance_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^rad")])
}
#' hidden function that greps for the transect field name
transect_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^tran")])
}
#' hidden function that greps for the timeperiod field name
timeperiod_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^tim")])
}
#' built-in (hidden) function that will accept the full path of a shapefile
#' and parse the string into something that rgdal can understand (DSN + Layer).
parseLayerDsn <- function(x=NULL){
  path <- unlist(strsplit(x, split="/"))
    layer <- gsub(path[length(path)],pattern=".shp",replacement="")
      dsn <- paste(path[1:(length(path)-1)],collapse="/")
  return(c(layer,dsn))
}
#' built-in (hidden) function that will accept the full path of a shapefile and read using rgdal::ogr
#' @param path argument provides the full path to an ESRI Shapefile
readOGRfromPath <- function(path=NULL, verbose=F){
  path <- OpenIMBCR:::parseLayerDsn(path)
  layer <- path[1]
    dsn <- path[2]
  return(rgdal:::readOGR(dsn,layer,verbose=verbose))
}
#' strip non-essential characters and spaces from a species common name in a field
strip_common_name <- function(x) tolower(gsub(x,pattern=" |'|-",replacement=""))
#' recursively find all files in folder (root) that match the pattern (name)
#' @export
recursive_find_file <- function(name=NULL,root=Sys.getenv("HOME")){
  if(is.null(name)){
    return(NULL)
  } else {
    return(list.files(root,pattern=name,recursive=T,full.names=T))
  }
}
#' parse a source CSV (published by BCR) for IMBCR data and return
#' as a SpatialPointsDataFrame to the user for post-processing or
#' conversion to unmarked data.frame objects for modeling
#' @export
imbcr_df_to_spatial_points <- function(filename=NULL,outfile=NULL,
                                  write=F, calc_spatial_covs=T){
  if(is.null(outfile) && write && !is.character(filename)){
    stop("cannot write shapefile to disk without an outfile= or filename.ext to parse")
  }
  # sanity-check to see if our output shapefile already exists
  s <- recursive_find_file(outfile)[1]
  if(!is.null(s)){
    s <- OpenIMBCR:::readOGRfromPath(s)
  # Parse ALL BCR raw data tables into a single table
  } else {
    if(inherits(filename,"data.frame")){
      t <- filename
    } else {
      if(length(filename)==1){
        t <- read.csv(filename)
      # legacy support : rbind across multiple CSV files
      } else {
        t <- lapply(recursive_find_file(
              name=filename
            ),
            read.csv
          )
        t <- do.call(rbind, t)
      }
    }
    names(t) <- tolower(names(t))
    #
    # iterate over each UTM zone in the table, creating SpatialPoints
    # projected to a focal UTM.  Then merge all of the zones together into
    # a single shapfile with an arbitrary CRS.
    #
    s <- list()
    for (zone in unique(na.omit(t$ptvisitzone))){
      s[[length(s) + 1]] <- na.omit(t[t$ptvisitzone == zone,])
      s[[length(s)]] <- sp::SpatialPointsDataFrame(
        coords = data.frame(
            x = s[[length(s)]]$ptvisiteasting,
            y = s[[length(s)]]$ptvisitnorthing
          ),
        data = s[[length(s)]],
        proj4string = sp::CRS(raster::projection(
            paste("+init=epsg:269", zone, sep = "")
          ))
      )
      # based on : http://gis.stackexchange.com/questions/155328/merging-multiple-spatialpolygondataframes-into-1-spdf-in-r
      row.names(s[[length(s)]]) <-
        paste(
          letters[length(s)],
          row.names(s[[length(s)]]),
          sep="."
        )
    }
    # merge our segments and convert to a consistent
    # popular CRS
    s <- do.call(
        sp::rbind.SpatialPointsDataFrame,
        lapply(
          s,
          FUN=sp::spTransform,
          sp::CRS(raster::projection("+init=epsg:2163"))
        ))
    s$FID <- 1:nrow(s)
    # calculate spatial (lat/lon) covariates for each station?
    if(calc_spatial_covs){
     # calculate lat/lon covariates in WGS84
     coords <- sp::spTransform(s,"+init=epsg:4326")@coords
       coords <- cbind(coords, coords^2, log10(coords+361))
         colnames(coords) <- c("lon","lat","lon_2","lat_2","ln_lon","ln_lat")
     s@data <- cbind(s@data,coords)
       rm(coords)
    }
    # write to disk -- and allow some wiggle-room on filename conventions
    if(write){
      rgdal::writeOGR(
        s,
        ".",
        ifelse(is.null(outfile),gsub(filename,pattern=".csv",replacement=""),outfile),
        driver="ESRI Shapefile",
        overwrite=T
      )
    }
  }
  return(s)
}
#' hidden function that will calculate the centroids of a USNG
#' (SpatialPolygons) and return only unique (non-duplicated)
#' units
drop_overlapping_units <- function(units=NULL){
   # warn if units don't appear to be projected in
   # meters, which would make our rounding below
   # inappropriate
   if(!grep(raster::projection(units), pattern="units=m")){
     warning("units= polygons do not appear to be metric -- we might over-estimate potential overlap")
   }
   duplicated <- duplicated(round(
       rgeos::gCentroid(units, byid=T)@coords
     ))
    return(
      units[!duplicated , ]
    )
}
#' accepts a named raster stack of covariates, an IMBCR SpatialPointsDataFrame,
#' and a species common name and returns a formatted unmarked distance data.frame
#' that can be used for model fitting with unmarked.
#' @export
build_unmarked_distance_df <- function(r=NULL, s=NULL, spp=NULL,
                                    vars=c("doy","starttime"), #
                                    fun=mean,
                                    d=c(0,100,200,300,400,500,600,700,800)){
  # do our covariates in r=raster stack occur in our IMBCR data.frame object?
  if(sum(names(r) %in% names(s@data))<raster::nlayers(r)){
    s <- suppressWarnings(raster::extract(r,s,sp=T))
      s$doy <- as.numeric(strftime(as.POSIXct(as.Date(as.character(s$date), "%m/%d/%Y")),format="%j")) # convert date -> doy
        s@data <- s@data[,!grepl(names(s@data),pattern="FID")]
  }
  # kludging to select the covariates specified in s= that we will aggregate
  # and use at the transect level
  if(!is.null(vars)){
    vars <- append(names(r), vars)
  } else {
    vars <- names(r)
  }
  # parse our dataset for RNEP records
  t <- s[s$common.name == spp,]@data
  # build a distance table
  distances <- data.frame(distance=t$radialdistance,transect=t$transectnum)
  y <- unmarked::formatDistData(distances, distCol="distance",transectNameCol="transect",dist.breaks=d)
  # build a target matrix
  stateCovariates <- matrix(NA,ncol=length(vars),nrow=length(levels(t$transectnum))) # e.g., 300 total transects x n state covariates
    rownames(stateCovariates) <- levels(t$transectnum)
  # aggregate by field
  for(i in 1:length(vars)){
    stateCovariates[,i] <- aggregate(s@data[,vars[i]], by=list(Category=s@data$transectnum), FUN=fun, na.rm=T)[,2]
  }
  # specify covariate names
  colnames(stateCovariates) <- vars
    stateCovariates <- data.frame(stateCovariates) # unmarked expects this ahtos a data.frame
  # format our training data as umf
  return(unmarked::unmarkedFrameDS(y=as.matrix(y), siteCovs=stateCovariates, survey="point", dist.breaks=d, unitsIn="m"))
}
#' kludging to back-fill any transect stations in an imbcr data.frame
#' that were sampled, but where a focal species wasn't observed, with
#' NA values.
#' @export
scrub_imbcr_df <- function(df,
                           allow_duplicate_timeperiods=F,
                           four_letter_code=NULL){
  LARGE_CLUSTER_SIZE=100
  # throw-out any lurking 88 values, count before start values, and
  # -1 distance observations
  df <- df[!df@data[, timeperiod_fieldname(df)] == 88, ]
  df <- df[!df@data[, timeperiod_fieldname(df)] == -1, ]
  df <- df[!df@data[, distance_fieldname(df)]   == -1, ]
  # build an empty (NA) data.frame for our species that we will populate with
  # valid values interatively
  df_final <- unique(df@data[,c('transectnum', 'year', 'point')])
  # add-in 6 minute periods for each station sampled
  df_final <- df_final[ sort(rep(1:nrow(unique(df@data[,c('transectnum', 'year', 'point')])), 6)), ]
  df_final <- cbind(df_final, data.frame(timeperiod=1:6))
  # drop in NA values for our species of interest
  df_final[, OpenIMBCR:::birdcode_fieldname(df)] <- four_letter_code
  df_final$cl_count <- NA
  df_final[ , OpenIMBCR:::distance_fieldname(df)] <- NA
  # iterate over df_final, pulling matches for our species of interest as we go
  columns_retained <- c('transectnum', 'year', 'point', 'timeperiod', 'birdcode', 'radialdistance', 'cl_count')
  # prepare to parallelize our large df operation
  cl <- parallel::makeCluster(LARGE_CLUSTER_SIZE)
  parallel::clusterExport(
    cl,
    varlist=c("df", "df_final","columns_retained"),
    envir=environment()
  )
  df_final <- do.call(rbind, parallel::parLapply(
      cl=cl,
      X=1:nrow(df_final),
      fun=function(i){
        query <- df_final[i, c('transectnum', 'year', 'point', 'timeperiod', 'birdcode')]
        match <- merge(df@data, query, all=F)
        if(nrow(match) == 0){
          # return some sane defaults if there was no match
          df_final[ i, 'radialdistance' ] <- NA
          df_final[ i, 'cl_count' ] <- 0
          return(df_final[i, columns_retained])
        } else {
          # the return here could have multiple rows in the same minute period
          return(match[ , columns_retained ])
        }
      }
  ))
  # clean-up
  parallel::stopCluster(cl);
  rm(cl);
  # return to user
  return(df_final)
}
#' accepts a formatted IMBCR SpatialPointsDataFrame and builds an
#' unmarkedFrameGDS data.frame that we can use for modeling with
#' the unmarked package.
#' @export
build_unmarked_gds <- function(df=NULL,
                               numPrimary=1,
                               distance_breaks=NULL,
                               covs=NULL,
                               unitsIn="m",
                               summary_fun=median,
                               drop_na_values=T
                               ){
  if(inherits(df, "Spatial")){
    df <- df@data
  }
  # determine distance breaks / classes, if needed
  if(is.null(distance_breaks)){
    distance_breaks  = df$distance_breaks
    distance_classes = append(sort(as.numeric(unique(
                            df$dist_class))),
                            NA
                          )
  } else {
    distance_classes = append(1:length(distance_breaks)-1, NA)
  }
  # parse our imbcr data.frame into transect-level summaries
  # with unmarked::gdistsamp comprehension
  transects <- unique(df[,transect_fieldname(df)])
  # pool our transect-level observations
  transects <- do.call(rbind,
      lapply(
          transects,
          FUN=pool_by_transect_year,
          df=df, breaks=distance_breaks,
          covs=covs
        )
    )
  # bug fix : drop entries with NA values before attempting PCA or quantile pruning
  if(drop_na_values){
    transects <- transects[ !as.vector(rowSums(is.na(transects)) > 0) , ]
    transects <- transects[ ,!grepl(colnames(transects), pattern="_NA")]
  }
  # build our unmarked frame and return to user
  return(unmarked::unmarkedFrameGDS(
      # distance bins
      y=transects[,grepl(names(transects),pattern="distance_")],
      # covariates that vary at the site (transect) level
      siteCovs=transects[,!grepl(colnames(transects),pattern="distance_")],
      # not used (covariates at the site-year level)
      yearlySiteCovs=NULL,
      survey="point",
      unitsIn=unitsIn,
      dist.breaks=distance_breaks,
      numPrimary=numPrimary # should be kept at 1 (no within-season visits)
    ))
}
#' hidden function used to clean-up an unmarked data.frame (umdf) by dropping
#' any NA columns attributed by scrub_imbcr_df(), mean-center (scale) our site
#' covariates (but not sampling effort!), and do some optional quantile filtering
#' that drops covariates with low variance, which is a useful 'significance
#' pruning' precursor for principal components analysis. Prefer dropping the NA
#' bin here (rather than in scrub_imbcr_df), so that we still have an accurate
#' account of total sampling effort to attribute in scrub_unmarked_dataframe().
scrub_unmarked_dataframe <- function(x=NULL, normalize=T, prune_cutoff=NULL){
  row.names(x@y) <- NULL
  row.names(x@siteCovs) <- NULL
  x@y <- x@y[,!grepl(colnames(x@y), pattern="_NA")]
  x@obsToY <- matrix(x@obsToY[,1:ncol(x@y)],nrow=1)
  # do some quantile pruning of our input data, selectively dropping
  # an arbitrary number of variables based on a user-specified
  # low-variance threshold
  if(!is.null(prune_cutoff)){
    # e.g., what is the total variance for each cov across all sites?
    # drop those standardized variables with < prune_cutoff=0.05 variance
    effort_field <- ifelse(
        sum(grepl(colnames(x@siteCovs), pattern="effort")),
        "effort",
        NULL
      )
    vars_to_scale <- colnames(x@siteCovs)[
        !grepl(tolower(colnames(x@siteCovs)), pattern="effort")
      ]
    # bug-fix : only try to prune numeric variables
    is_numeric <- apply(
        x@siteCovs[1,vars_to_scale],
        MARGIN=2,
        FUN=function(x) !is.na(suppressWarnings(as.numeric(x)))
      )
    if(length(vars_to_scale)!=sum(is_numeric)){
      warning(paste(
          "the following input variables are not numeric and cannot be",
          "filtered by quantile and will not be pruned:",
          paste(
              vars_to_scale[!is_numeric],
              collapse=", "
            )
        ))
      vars_to_scale <- vars_to_scale[is_numeric]
    }
    # calculate relative variance across all sites for each variable (column)
    variance <- apply(
      x@siteCovs[,vars_to_scale],
      MARGIN=2,
      FUN=function(x) ( (x - min(x)) / (max(x)-min(x)) ) # quick min-max normalize
    )
    # min-max will return NA on no variance (e.g., divide by zero)
    variance[is.na(variance)] <- 0
    variance <- apply(
        variance,
        MARGIN=2,
        FUN=var
      )
    # drop variables that don't meet our a priori variance threshold
    dropped <- as.vector(variance < quantile(variance, p=prune_cutoff))
    if(sum(dropped)>0){
      warning(paste(
        "prune_cutoff dropped these variables due to very small variance: ",
        paste(colnames(x@siteCovs[,vars_to_scale])[dropped], collapse=", "),
        sep=""
      ))
      keep <- unique(c(
        names(is_numeric[!is_numeric]),
        effort_field,
        vars_to_scale[!dropped]
      ))
      x@siteCovs <- x@siteCovs[, keep]
    }
  }
  # normalize our site covariates?
  if(normalize){
    # don't try to normalize non-numeric values -- drop these as site covs
    x@siteCovs <-
      x@siteCovs[ , as.vector(unlist(lapply(x@siteCovs[1,], FUN=is.numeric)))]
    # don't normalize the "effort" field
    vars_to_scale <- colnames(x@siteCovs)[
        !grepl(tolower(colnames(x@siteCovs)), pattern="effort")
      ]
    # scaling call
    x@siteCovs[,vars_to_scale] <- as.data.frame(
        scale(x@siteCovs[,vars_to_scale])
      )
    # sanity check : do some variable pruning based on variance
    # from our normalization step -- drop variables with low variance
    # from consideration and report dropped variables to user
    dropped <- as.vector(unlist(lapply(x@siteCovs[1,], FUN=is.na)))
    if(sum(dropped)>0){
      warning(paste(
        "scale() dropped these variables due to very small variance: ",
        paste(colnames(x@siteCovs)[dropped], collapse=", "),
        sep=""
      ))
      x@siteCovs <- x@siteCovs[,!dropped]
    }
  }
  return(x)
}
#' will generate a uniform vector grid within a polygon. Typically
#' this is a 250 meter grid, but the size of each
#' grid cell is arbitrary. Will return units as SpatialPolygons.
polygon_to_fishnet_grid <- function(
  usng_unit=NULL,
  res=250,
  x_offset=0,
  y_offset=0,
  clip=F,
  centers=F
){
    MIN_UNIT_SIZE    = rgeos::gArea(usng_unit) * 0.03
    ZIPPER_UNIT_SIZE = 600245.2 # ~60% of a full USNG unit
    N_SUBUNITS       = round(rgeos::gArea(usng_unit) / res^2)
    # sanity check our unit size
    if ( rgeos::gArea(usng_unit) < ZIPPER_UNIT_SIZE ){
      warning("dropping zipper grid unit")
      return(NA)
    }
    # solves for the rotation parameter in 'sf' function
    rotate <- function(a) matrix(c(cos(a), sin(a), -sin(a), cos(a)), 2, 2)
    # get the bounding-box point coords for our unit -- the slot
    # handling is sloppy here and may break in the future
    ul <- which.max(usng_unit@polygons[[1]]@Polygons[[1]]@coords[,2])
      ul <- usng_unit@polygons[[1]]@Polygons[[1]]@coords[ul,]
    ur <- which.max(usng_unit@polygons[[1]]@Polygons[[1]]@coords[,1])
      ur <- usng_unit@polygons[[1]]@Polygons[[1]]@coords[ur,]
    ll <- which.min(usng_unit@polygons[[1]]@Polygons[[1]]@coords[,1])
      ll <- usng_unit@polygons[[1]]@Polygons[[1]]@coords[ll,]
    # dig up old Pythagoras and solve for the hypotenuse -- we will
    # use this to solve for our angle of rotation
    opp <- ul[2]-ur[2]
    adj <- ur[1]-ul[1]
    hyp <- sqrt(opp^2 + adj^2)
    # here's the angle of rotation associated with each 250 m
    # grid unit
    theta <- asin(opp/hyp) * 57.29578 # convert radians-to-degrees
    #print(theta)
    # build-out our grid using per-unit specifications
    grd <- try(sf::st_make_grid(
        usng_unit,
        n=c(sqrt(N_SUBUNITS),sqrt(N_SUBUNITS)),
        what="polygons",
        crs=sp::CRS(raster::projection(usng_unit)),
        square=T
    ))
    if( inherits(grd, "try-error") ){
      warning(
        "sf::st_make_grid failed to generate subunits from parent unit ",
        "features -- returning NA"
      )
      return(NA)
    }
    if( length(grd) < N_SUBUNITS){
      warning(
        "sf::st_make_grid failed to generate enough subunits -- ",
        "returning NA"
      )
      return(NA)
    }
    # if we aren't using the n= specification for st_make_grid,
    # we'll need to rotate our units so they are spatially
    # consistent with our parent unit
    # grd_rot <- (grd - sf::st_centroid(sf::st_union(grd))) *
    #   rotate(theta * pi / 180) + sf::st_centroid(sf::st_union(grd))
    # testing: the n= specification can accomodate our rotation for us?
    grd_rot <- grd
    grd_rot <- try(sf::as_Spatial(grd_rot))
    if( inherits(grd_rot, 'try-error') ){
      warning(
        "sf::as_Spatial may have encountered some failed geometries ",
        "in our generated subgrid -- here is a print-out of the geometries: ",
        as.character(as.data.frame(grd))
      )
      return(NA)
    }
    # restore our projection to the adjusted grid
    raster::projection(grd_rot) <- raster::projection(usng_unit)
    # make sure we clip any boundaries for grid units so the grid is
    # fully consistent with the larger polygon unit
    if(clip){
      grd_rot <- rgeos::gIntersection(
        grd_rot,
        usng_unit,
        byid=T
      )
      # drop any slivers from our intersect operation
      slivers <- sapply(
        sp::split(grd_rot, seq_len(nrow(grd_rot))),
        FUN=rgeos::gArea
      ) < MIN_UNIT_SIZE

      grd_rot <- grd_rot[!slivers,]
    }
    # attribute station id's in a funky zig-zag pattern typically
    # used with IMBCR sampling
    if(centers){
      grd_rot <- rgeos::gCentroid(
        grd_rot,
        byid=T
      )
      # sort rows (latitude) by increasing longitudinal-values
      rows <- sort(unique(round(sp::coordinates(grd_rot)[,2])), decreasing=T)
      coords_order <- vector()
      for(row in rows){
        coords   <- round(coordinates(grd_rot))
        y_coords <- coords[,2]
        # sort this row by decreasing longitude values
        coords_order <- append(
          coords_order,
          names(sort(coords[y_coords == row , 1], decreasing=T))
        )
      }
      grd_rot <- sp::SpatialPointsDataFrame(
        sp::coordinates(grd_rot)[coords_order,],
        data=data.frame(station=seq_len(N_SUBUNITS))
      )
      raster::projection(grd_rot) <- raster::projection(usng_unit)
    }
    # last sanity check
    if( length(grd_rot) < N_SUBUNITS){
      warning("failed to generate enough subunits for polygon features")
      return(NA)
    }
    return(grd_rot)
}
#' generate a uniform fishnet grid for a variable polygon dataset containing
#' one or more geometries. Will fix the rotation of the grid using the bounding
#' box of the polygon dataset.
#' @export
generate_fishnet_grid <- function(units=NULL, res=251){
  units <- sp::split(units, 1:nrow(units))
  e_cl <- parallel::makeCluster(parallel::detectCores()*0.75)
  parallel::clusterExport(e_cl, varlist=c('res'), envir=environment())
  units <- parallel::parLapply(
      cl = e_cl,
      X = units,
      fun = function(unit){
        return(
          OpenIMBCR:::polygon_to_fishnet_grid(unit, res=res)
        )
      }
    )
  # clean-up our parallelized operation
  parallel::stopCluster(e_cl); rm(e_cl);
  # accept that some zipper units may product NA values that we drop here
  SUCCEEDED <- sapply(
      units,
      FUN=function(x) inherits(x, 'SpatialPolygons')
    )
  # drop the failures and return to user a single SpatialPolygonsDataFrame
  units <- do.call(
    sp::rbind.SpatialPolygons,
    units[SUCCEEDED]
  )
  # force consistent naming of our polygon ID's for SpatialPolygonsDataFrame()
  units@polygons <- lapply(
      X=1:length(units@polygons),
      function(i){ f <- units@polygons[[i]]; f@ID <- as.character(i); return(f) }
    )
  return(
    SpatialPolygonsDataFrame(units, data=data.frame(id=1:length(units@polygons)))
  )
}
