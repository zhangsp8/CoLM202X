#include <define.h>

SUBROUTINE Aggregation_LAI (gridlai, dir_rawdata, dir_model_landdata)
   ! ----------------------------------------------------------------------
   ! 1. Global land cover types (updated with the specific dataset)
   !
   ! 2. Global Plant Leaf Area Index
   !    (http://globalchange.bnu.edu.cn)
   !    Yuan H., et al., 2011:
   !    Reprocessing the MODIS Leaf Area Index products for land surface
   !    and climate modelling. Remote Sensing of Environment, 115: 1171-1187.
   !
   ! Created by Yongjiu Dai, 02/2014
   !
   !
   ! ----------------------------------------------------------------------
   USE MOD_Precision
   USE MOD_Vars_Global
   USE MOD_Namelist
   USE MOD_SPMD_Task
   USE MOD_Grid
   USE MOD_LandPatch
   USE MOD_NetCDFBlock
   USE MOD_NetCDFVector
#ifdef CoLMDEBUG
   USE MOD_CoLMDebug
#endif

   USE MOD_AggregationRequestData

   USE MOD_Const_LC
   USE MOD_5x5DataReadin
#ifdef PFT_CLASSIFICATION
   USE MOD_LandPFT
#endif
#ifdef PC_CLASSIFICATION
   USE MOD_LandPC
#endif
#ifdef SinglePoint
   USE MOD_SingleSrfdata
#endif

#ifdef SrfdataDiag
   USE MOD_SrfdataDiag
#endif

   IMPLICIT NONE

   ! arguments:

   TYPE(grid_type),  intent(in) :: gridlai
   CHARACTER(LEN=*), intent(in) :: dir_rawdata
   CHARACTER(LEN=*), intent(in) :: dir_model_landdata

   ! local variables:
   ! ----------------------------------------------------------------------
   CHARACTER(len=256) :: landdir, lndname

   TYPE (block_data_real8_2d) :: LAI          ! plant leaf area index (m2/m2)
   REAL(r8), allocatable :: LAI_patches(:), lai_one(:), area_one(:)
   INTEGER :: itime, ntime, Julian_day, ipatch
   CHARACTER(LEN=4) :: c2, c3, cyear
   integer :: start_year, end_year, iy

   ! for IGBP data
   CHARACTER(len=256) :: dir_5x5, suffix
   INTEGER :: month
   TYPE (block_data_real8_2d) :: SAI          ! plant stem area index (m2/m2)
   REAL(r8), allocatable :: SAI_patches(:), sai_one(:)

   ! for PFT
   TYPE (block_data_real8_3d) :: pftLSAI, pftPCT
   REAL(r8), allocatable :: pct_one (:), pct_pft_one(:,:)
   REAL(r8), allocatable :: LAI_pfts(:), lai_pft_one(:,:)
   REAL(r8), allocatable :: SAI_pfts(:), sai_pft_one(:,:)
   INTEGER :: p, ip

   ! for PC
   REAL(r8), allocatable :: LAI_pcs(:,:), SAI_pcs(:,:)
   INTEGER :: ipc, ipft
   REAL(r8) :: sumarea

#ifdef SrfdataDiag
   INTEGER :: typpatch(N_land_classification+1), ityp
#ifndef CROP
   INTEGER :: typpft  (N_PFT)
#else
   INTEGER :: typpft  (N_PFT+N_CFT)
#endif
   CHARACTER(len=256) :: varname
#endif

   ! LAI data root directory->case/landdata/LAI
   landdir = trim(dir_model_landdata) // '/LAI/'

#ifdef USEMPI
   CALL mpi_barrier (p_comm_glb, p_err)
#endif
   IF (p_is_master) THEN
      write(*,'(/, A)') 'Aggregate LAI ...'
      CALL system('mkdir -p ' // trim(adjustl(landdir)))
   ENDIF
#ifdef USEMPI
   CALL mpi_barrier (p_comm_glb, p_err)
#endif

#ifdef SinglePoint
   IF (USE_SITE_LAI) THEN
      RETURN
   ENDIF
#endif

   ! ................................................
   ! ... global plant leaf area index
   ! ................................................

#if (defined USGS_CLASSIFICATION || defined IGBP_CLASSIFICATION)
   ! add time variation of LAI
   IF (DEF_LAI_CLIM) THEN
      ! monthly average LAI
      ! if use lai change, LAI data of simulation start year and end year will be made
      ! if not use lai change, only make LAI data of defined lc year
      IF (DEF_LAICHANGE) THEN
         start_year = DEF_simulation_time%start_year
         end_year   = DEF_simulation_time%end_year
         ntime      = 12
      ELSE
         start_year = DEF_LC_YEAR
         end_year   = DEF_LC_YEAR
         ntime      = 12
      ENDIF
   ! 8-day LAI
   ELSE
      start_year = DEF_simulation_time%start_year
      end_year   = DEF_simulation_time%end_year
      ntime      = 46
   ENDIF

   ! ----- LAI -----
   IF (p_is_io) THEN
      CALL allocate_block_data (gridlai, LAI)
   ENDIF

   IF (p_is_worker) THEN
      allocate (LAI_patches (numpatch))
   ENDIF

#ifdef SinglePoint
   IF (DEF_LAI_CLIM) THEN
      allocate (SITE_LAI_clim (12))
   ELSE
      allocate (SITE_LAI_year (start_year:end_year))
      SITE_LAI_year = (/(iy, iy = start_year, end_year)/)

      allocate (SITE_LAI_modis (46,start_year:end_year))
   ENDIF
#endif

   DO iy = start_year, end_year

      !IF (.not. DEF_LAI_CLIM) THEN
      ! lai data of each year -> case/landdata/year
      write(cyear,'(i4.4)') iy
      CALL system('mkdir -p ' // trim(landdir) // trim(cyear))
      !ENDIF

      ! loop for month or 8-day
      DO itime = 1, ntime
         ! -----------------------
         ! read in leaf area index
         ! -----------------------
         IF (DEF_LAI_CLIM) THEN
            write(c3, '(i2.2)') itime
         ELSE
            Julian_day = 1 + (itime-1)*8
            write(c3, '(i3.3)') Julian_day
         ENDIF

         IF (p_is_master) THEN
            write(*,'(A,I4,A1,I3,A1,I3)') 'Aggregate LAI :', iy, ':', itime, '/', ntime
         endif

         IF (p_is_io) THEN
            IF (DEF_LAI_CLIM) THEN
               dir_5x5 = trim(dir_rawdata) // '/plant_15s_clim'
               suffix  = 'MOD'//trim(cyear)
               CALL read_5x5_data_time (dir_5x5, suffix, gridlai, 'MONTHLY_LC_LAI', itime, LAI)
            ELSE
               lndname = trim(dir_rawdata)//'/lai_15s_8day/lai_8-day_15s_'//trim(cyear)//'.nc'
               CALL ncio_read_block_time (lndname, 'lai', gridlai, itime, LAI)
               CALL block_data_linear_transform (LAI, scl = 0.1)
            ENDIF

#ifdef USEMPI
            CALL aggregation_data_daemon (gridlai, data_r8_2d_in1 = LAI)
#endif
         ENDIF

         ! ---------------------------------------------------------------
         ! aggregate the plant leaf area index from the resolution of raw data to modelling resolution
         ! ---------------------------------------------------------------

         IF (p_is_worker) THEN
            DO ipatch = 1, numpatch
               CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                  data_r8_2d_in1 = LAI, data_r8_2d_out1 = lai_one)
               LAI_patches(ipatch) = sum(lai_one * area_one) / sum(area_one)
            ENDDO

#ifdef USEMPI
            CALL aggregation_worker_done ()
#endif
         ENDIF

#ifdef CoLMDEBUG
         CALL check_vector_data ('LAI value '//trim(c3), LAI_patches)
#endif

#ifdef USEMPI
         CALL mpi_barrier (p_comm_glb, p_err)
#endif
         ! ---------------------------------------------------
         ! write out the plant leaf area index of grid patches
         ! ---------------------------------------------------
#ifndef SinglePoint
         IF (DEF_LAI_CLIM) THEN
            lndname = trim(landdir) // trim(cyear) // '/LAI_patches' // trim(c3) // '.nc'
         ELSE
            !TODO: rename filename of 8-day LAI
            lndname = trim(landdir) // trim(cyear) // '/LAI_patches' // trim(c3) // '.nc'
         ENDIF

         CALL ncio_create_file_vector (lndname, landpatch)
         CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
         CALL ncio_write_vector (lndname, 'LAI_patches', 'patch', landpatch, LAI_patches, 1)

#ifdef SrfdataDiag
         typpatch = (/(ityp, ityp = 0, N_land_classification)/)
         lndname  = trim(dir_model_landdata) // '/diag/LAI_patch_'// trim(cyear) // '.nc'
         IF (DEF_LAI_CLIM) THEN
            varname = 'LAI_' // trim(c3)
         ELSE
            !TODO: rename file name of 8-day LAI
            varname = 'LAI_8-day_' // '_' // trim(c3)
         ENDIF
         CALL srfdata_map_and_write (LAI_patches, landpatch%settyp, typpatch, m_patch2diag, &
            -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif
#else
         ! single point cases
         !TODO: parameter input for time year
         IF (DEF_LAI_CLIM) THEN
            SITE_LAI_clim(itime) = LAI_patches(1)
         ELSE
            SITE_LAI_modis(itime,iy) = LAI_patches(1)
         ENDIF
#endif
      ENDDO
   ENDDO

   ! ----- SAI -----
   IF (DEF_LAI_CLIM) THEN

      IF (p_is_io) THEN
         CALL allocate_block_data (gridlai, SAI)
      ENDIF

      IF (p_is_worker) THEN
         allocate (SAI_patches (numpatch))
      ENDIF

#ifdef SinglePoint
      allocate (SITE_SAI_clim (12))
#endif

      dir_5x5 = trim(dir_rawdata) // '/plant_15s_clim'
      DO iy = start_year, end_year
         write(cyear,'(i4.4)') iy
         suffix  = 'MOD'//trim(cyear)

         DO itime = 1, 12
            write(c3, '(i2.2)') itime

            IF (p_is_master) THEN
               write(*,'(A,I3,A1,I3)') 'Aggregate SAI :', itime, '/', ntime
            endif

            IF (p_is_io) THEN
               CALL read_5x5_data_time (dir_5x5, suffix, gridlai, 'MONTHLY_LC_SAI', itime, SAI)

#ifdef USEMPI
               CALL aggregation_data_daemon (gridlai, data_r8_2d_in1 = SAI)
#endif
            ENDIF

            ! ---------------------------------------------------------------
            ! aggregate the plant stem area index from the resolution of raw data to modelling resolution
            ! ---------------------------------------------------------------

            IF (p_is_worker) THEN
               DO ipatch = 1, numpatch

                  CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                     data_r8_2d_in1 = SAI, data_r8_2d_out1 = sai_one)
                  SAI_patches(ipatch) = sum(sai_one * area_one) / sum(area_one)

               ENDDO

#ifdef USEMPI
               CALL aggregation_worker_done ()
#endif
            ENDIF

#ifdef CoLMDEBUG
         CALL check_vector_data ('SAI value '//trim(c3), SAI_patches)
#endif

#ifdef USEMPI
            CALL mpi_barrier (p_comm_glb, p_err)
#endif
            ! ---------------------------------------------------
            ! write out the plant leaf area index of grid patches
            ! ---------------------------------------------------
#ifndef SinglePoint
            lndname = trim(landdir) // trim(cyear) // '/SAI_patches' // trim(c3) // '.nc'
            CALL ncio_create_file_vector (lndname, landpatch)
            CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
            CALL ncio_write_vector (lndname, 'SAI_patches', 'patch', landpatch, SAI_patches, 1)

#ifdef SrfdataDiag
            typpatch = (/(ityp, ityp = 0, N_land_classification)/)
            lndname  = trim(dir_model_landdata) // '/diag/SAI_patch_'// trim(cyear) // '.nc'
            IF (DEF_LAI_CLIM) THEN
               varname = 'SAI_' // trim(c3)
            ELSE
               !TODO: rename varname
               varname = 'SAI_8-day_' // '_' // trim(c3)
            ENDIF
            CALL srfdata_map_and_write (SAI_patches, landpatch%settyp, typpatch, m_patch2diag, &
               -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif
#else
            !TODO: single point case
            SITE_SAI_clim(itime) = SAI_patches(1)
#endif
         ENDDO
      ENDDO
   ENDIF
#endif

! PFT LAI!!!!!
#ifdef PFT_CLASSIFICATION
   ! add time variation of LAI
   ! monthly average LAI
   ! if use lai change, LAI data of simulation start year and end year will be made
   ! if not use lai change, only make LAI data of defined lc year
   IF (DEF_LAICHANGE) THEN
      start_year = DEF_simulation_time%start_year
      end_year   = DEF_simulation_time%end_year
      ntime      = 12
   ELSE
      start_year = DEF_LC_YEAR
      end_year   = DEF_LC_YEAR
      ntime      = 12
   ENDIF

   IF (p_is_io) THEN
      CALL allocate_block_data (gridlai, pftLSAI, N_PFT_modis, lb1 = 0)
      CALL allocate_block_data (gridlai, pftPCT,  N_PFT_modis, lb1 = 0)
   ENDIF

   IF (p_is_worker) THEN
      allocate(LAI_patches (numpatch))
      allocate(LAI_pfts    (numpft  ))
      allocate(SAI_patches (numpatch))
      allocate(SAI_pfts    (numpft  ))
   ENDIF

#ifdef SinglePoint
   !TODO: single point case
   allocate (SITE_LAI_pfts_clim (numpft,12))
   allocate (SITE_SAI_pfts_clim (numpft,12))
#endif

   dir_5x5 = trim(dir_rawdata) // '/plant_15s_clim'
   DO iy = start_year, end_year
      write(cyear,'(i4.4)') iy
      suffix  = 'MOD'//trim(cyear)

      IF (p_is_io) THEN
         CALL read_5x5_data_pft (dir_5x5, suffix, gridlai, 'PCT_PFT', pftPCT)
      ENDIF

      DO month = 1, 12
         IF (p_is_io) THEN
            CALL read_5x5_data_pft_time (dir_5x5, suffix, gridlai, 'MONTHLY_PFT_LAI', month, pftLSAI)
#ifdef USEMPI
            CALL aggregation_data_daemon (gridlai, &
               data_r8_3d_in1 = pftPCT,  n1_r8_3d_in1 = 16, &
               data_r8_3d_in2 = pftLSAI, n1_r8_3d_in2 = 16)
#endif
         ENDIF

         ! ---------------------------------------------------------------
         ! aggregate the plant leaf area index from the resolution of raw data to modelling resolution
         ! ---------------------------------------------------------------

         IF (p_is_worker) THEN
            DO ipatch = 1, numpatch
               CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                  data_r8_3d_in1 = pftPCT,  data_r8_3d_out1 = pct_pft_one, n1_r8_3d_in1 = 16, lb1_r8_3d_in1 = 0, &
                  data_r8_3d_in2 = pftLSAI, data_r8_3d_out2 = lai_pft_one, n1_r8_3d_in2 = 16, lb1_r8_3d_in2 = 0)

               IF (allocated(lai_one)) deallocate(lai_one)
               allocate(lai_one(size(area_one)))

               IF (allocated(pct_one)) deallocate(pct_one)
               allocate(pct_one(size(area_one)))

               pct_one = sum(pct_pft_one,dim=1)
               pct_one = max(pct_one, 1.0e-6)

               lai_one = sum(lai_pft_one * pct_pft_one, dim=1) / pct_one
               LAI_patches(ipatch) = sum(lai_one * area_one) / sum(area_one)

               IF (landpatch%settyp(ipatch) == 1) THEN
                  DO ip = patch_pft_s(ipatch), patch_pft_e(ipatch)
                     p = landpft%settyp(ip)
                     sumarea = sum(pct_pft_one(p,:) * area_one)
                     IF (sumarea > 0) THEN
                        LAI_pfts(ip) = sum(lai_pft_one(p,:) * pct_pft_one(p,:) * area_one) / sumarea
                     ELSE
                        LAI_pfts(ip) = LAI_patches(ipatch)
                     ENDIF
                  ENDDO
#ifdef CROP
               ELSEIF (landpatch%settyp(ipatch) == 12) THEN
                  ip = patch_pft_s(ipatch)
                  LAI_pfts(ip) = LAI_patches(ipatch)
#endif
               ENDIF
            ENDDO

#ifdef USEMPI
            CALL aggregation_worker_done ()
#endif
         ENDIF

      write(c2,'(i2.2)') month
#ifdef CoLMDEBUG
      CALL check_vector_data ('LAI_patches ' // trim(c2), LAI_patches)
      CALL check_vector_data ('LAI_pfts    ' // trim(c2), LAI_pfts   )
#endif
#ifdef USEMPI
         CALL mpi_barrier (p_comm_glb, p_err)
#endif

         ! ---------------------------------------------------
         ! write out the plant leaf area index of grid patches
         ! ---------------------------------------------------
#ifndef SinglePoint
         lndname = trim(landdir)//trim(cyear)//'/LAI_patches'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpatch)
         CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
         CALL ncio_write_vector (lndname, 'LAI_patches', 'patch', landpatch, LAI_patches, 1)

#ifdef SrfdataDiag
         typpatch = (/(ityp, ityp = 0, N_land_classification)/)
         lndname  = trim(dir_model_landdata) // '/diag/LAI_patch_' // trim(cyear) // '.nc'
         varname  = 'LAI_' // trim(c2)
         CALL srfdata_map_and_write (LAI_patches, landpatch%settyp, typpatch, m_patch2diag, &
            -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif

         lndname = trim(landdir)//trim(cyear)//'/LAI_pfts'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpft)
         CALL ncio_define_dimension_vector (lndname, landpft, 'pft')
         CALL ncio_write_vector (lndname, 'LAI_pfts', 'pft', landpft, LAI_pfts, 1)

#ifdef SrfdataDiag
#ifndef CROP
         typpft  = (/(ityp, ityp = 0, N_PFT-1)/)
#else
         typpft  = (/(ityp, ityp = 0, N_PFT+N_CFT-1)/)
#endif
         lndname = trim(dir_model_landdata) // '/diag/LAI_pft_' // trim(cyear) // '.nc'
         varname = 'LAI_pft_' // trim(c2)
         CALL srfdata_map_and_write (LAI_pfts, landpft%settyp, typpft, m_pft2diag, &
            -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif
#else
         !TODO: single point case
         SITE_LAI_pfts_clim(:,month) = LAI_pfts(:)
#endif
      ! loop end of month
      ENDDO

      ! IF (p_is_worker) THEN
      !    IF (allocated(LAI_patches)) deallocate(LAI_patches)
      !    IF (allocated(LAI_pfts   )) deallocate(LAI_pfts   )
      !    IF (allocated(lai_one    )) deallocate(lai_one    )
      !    IF (allocated(pct_one    )) deallocate(pct_one    )
      !    IF (allocated(pct_pft_one)) deallocate(pct_pft_one)
      !    IF (allocated(area_one   )) deallocate(area_one   )
      ! ENDIF

      DO month = 1, 12
         IF (p_is_io) THEN
            CALL read_5x5_data_pft_time (dir_5x5, suffix, gridlai, 'MONTHLY_PFT_SAI', month, pftLSAI)
#ifdef USEMPI
            CALL aggregation_data_daemon (gridlai, &
               data_r8_3d_in1 = pftPCT,  n1_r8_3d_in1 = 16, &
               data_r8_3d_in2 = pftLSAI, n1_r8_3d_in2 = 16)
#endif
         ENDIF

         ! ---------------------------------------------------------------
         ! aggregate the plant leaf area index from the resolution of raw data to modelling resolution
         ! ---------------------------------------------------------------

         IF (p_is_worker) THEN
            DO ipatch = 1, numpatch

               CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                  data_r8_3d_in1 = pftPCT,  data_r8_3d_out1 = pct_pft_one, n1_r8_3d_in1 = 16, lb1_r8_3d_in1 = 0, &
                  data_r8_3d_in2 = pftLSAI, data_r8_3d_out2 = sai_pft_one, n1_r8_3d_in2 = 16, lb1_r8_3d_in2 = 0)

               IF (allocated(sai_one)) deallocate(sai_one)
               allocate(sai_one(size(area_one)))

               IF (allocated(pct_one)) deallocate(pct_one)
               allocate(pct_one(size(area_one)))

               pct_one = sum(pct_pft_one,dim=1)
               pct_one = max(pct_one, 1.0e-6)

               sai_one = sum(sai_pft_one * pct_pft_one, dim=1) / pct_one
               SAI_patches(ipatch) = sum(sai_one * area_one) / sum(area_one)

               IF (landpatch%settyp(ipatch) == 1) THEN
                  DO ip = patch_pft_s(ipatch), patch_pft_e(ipatch)
                     p = landpft%settyp(ip)
                     sumarea = sum(pct_pft_one(p,:) * area_one)
                     IF (sumarea > 0) THEN
                        SAI_pfts(ip) = sum(sai_pft_one(p,:) * pct_pft_one(p,:) * area_one) / sumarea
                     ELSE
                        SAI_pfts(ip) = SAI_patches(ipatch)
                     ENDIF
                  ENDDO
#ifdef CROP
               ELSEIF (landpatch%settyp(ipatch) == 12) THEN
                  ip = patch_pft_s(ipatch)
                  SAI_pfts(ip) = SAI_patches(ipatch)
#endif
               ENDIF
            ENDDO

#ifdef USEMPI
            CALL aggregation_worker_done ()
#endif
         ENDIF

      write(c2,'(i2.2)') month
#ifdef CoLMDEBUG
      CALL check_vector_data ('SAI_patches ' // trim(c2), SAI_patches)
      CALL check_vector_data ('SAI_pfts    ' // trim(c2), SAI_pfts   )
#endif
#ifdef USEMPI
         CALL mpi_barrier (p_comm_glb, p_err)
#endif

         ! ---------------------------------------------------
         ! write out the plant stem area index of grid patches
         ! ---------------------------------------------------
#ifndef SinglePoint
         lndname = trim(landdir)//trim(cyear)//'/SAI_patches'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpatch)
         CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
         CALL ncio_write_vector (lndname, 'SAI_patches', 'patch', landpatch, SAI_patches, 1)

#ifdef SrfdataDiag
         typpatch = (/(ityp, ityp = 0, N_land_classification)/)
         lndname  = trim(dir_model_landdata) // '/diag/SAI_patch_'// trim(cyear) // '.nc'
         varname  = 'SAI_' // trim(c2)
         CALL srfdata_map_and_write (SAI_patches, landpatch%settyp, typpatch, m_patch2diag, &
            -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif

         lndname = trim(landdir)//trim(cyear)//'/SAI_pfts'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpft)
         CALL ncio_define_dimension_vector (lndname, landpft, 'pft')
         CALL ncio_write_vector (lndname, 'SAI_pfts', 'pft', landpft, SAI_pfts, 1)

#ifdef SrfdataDiag
#ifndef CROP
         typpft  = (/(ityp, ityp = 0, N_PFT-1)/)
#else
         typpft  = (/(ityp, ityp = 0, N_PFT+N_CFT-1)/)
#endif
         lndname = trim(dir_model_landdata) // '/diag/SAI_pft_'// trim(cyear) // '.nc'
         varname = 'SAI_pft_' // trim(c2)
         CALL srfdata_map_and_write (SAI_pfts, landpft%settyp, typpft, m_pft2diag, &
            -1.0e36_r8, lndname, trim(varname), compress = 0, write_mode = 'one')
#endif
#else
         SITE_SAI_pfts_clim(:,month) = SAI_pfts(:)
#endif
      ! loop end of month
      ENDDO
   ! loop end of year
   ENDDO

   IF (p_is_worker) THEN
      IF (allocated(LAI_patches)) deallocate(LAI_patches)
      IF (allocated(LAI_pfts   )) deallocate(LAI_pfts   )
      IF (allocated(lai_one    )) deallocate(lai_one    )

      IF (allocated(SAI_patches)) deallocate(SAI_patches)
      IF (allocated(SAI_pfts   )) deallocate(SAI_pfts   )
      IF (allocated(sai_one    )) deallocate(sai_one    )
      IF (allocated(pct_one    )) deallocate(pct_one    )
      IF (allocated(pct_pft_one)) deallocate(pct_pft_one)
      IF (allocated(area_one   )) deallocate(area_one   )
   ENDIF
#endif

! PC LAI!!!!!!!!
#ifdef PC_CLASSIFICATION
   ! add time variation of LAI
   ! monthly average LAI
   ! if use lai change, LAI data of simulation start year and end year will be made
   ! if not use lai change, only make LAI data of defined lc year
   IF (DEF_LAICHANGE) THEN
      start_year = DEF_simulation_time%start_year
      end_year   = DEF_simulation_time%end_year
      ntime      = 12
   ELSE
      start_year = DEF_LC_YEAR
      end_year   = DEF_LC_YEAR
      ntime      = 12
   ENDIF

   IF (p_is_io) THEN
      CALL allocate_block_data (gridlai, pftLSAI, N_PFT_modis, lb1 = 0)
      CALL allocate_block_data (gridlai, pftPCT,  N_PFT_modis, lb1 = 0)
   ENDIF

   IF (p_is_worker) THEN
      allocate(LAI_patches (numpatch))
      allocate(LAI_pcs (0:N_PFT-1, numpc))
      allocate(SAI_patches (numpatch))
      allocate(SAI_pcs (0:N_PFT-1, numpc))
   ENDIF

#ifdef SinglePoint
   !TODO: singles case
   allocate (SITE_LAI_pfts_clim (0:N_PFT-1,12))
   allocate (SITE_SAI_pfts_clim (0:N_PFT-1,12))
#endif

   dir_5x5 = trim(dir_rawdata) // '/plant_15s_clim'
   DO iy = start_year, end_year
      write(cyear,'(i4.4)') iy
      suffix  = 'MOD'//trim(cyear)

      IF (p_is_io) THEN
         CALL read_5x5_data_pft (dir_5x5, suffix, gridlai, 'PCT_PFT', pftPCT)
      ENDIF

      DO month = 1, 12
         IF (p_is_io) THEN
            ! change var name to MONTHLY_PFT_LAI
            CALL read_5x5_data_pft_time (dir_5x5, suffix, gridlai, 'MONTHLY_PFT_LAI', month, pftLSAI)
#ifdef USEMPI
            CALL aggregation_data_daemon (gridlai, &
               data_r8_3d_in1 = pftPCT,  n1_r8_3d_in1 = 16, &
               data_r8_3d_in2 = pftLSAI, n1_r8_3d_in2 = 16)
#endif
         ENDIF

         ! ---------------------------------------------------------------
         ! aggregate the plant leaf area index from the resolution of raw data to modelling resolution
         ! ---------------------------------------------------------------

         IF (p_is_worker) THEN
            DO ipatch = 1, numpatch
               CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                  data_r8_3d_in1 = pftPCT,  data_r8_3d_out1 = pct_pft_one, n1_r8_3d_in1 = 16, lb1_r8_3d_in1 = 0, &
                  data_r8_3d_in2 = pftLSAI, data_r8_3d_out2 = lai_pft_one, n1_r8_3d_in2 = 16, lb1_r8_3d_in2 = 0)

               IF (allocated(lai_one)) deallocate(lai_one)
               allocate(lai_one(size(area_one)))

               IF (allocated(pct_one)) deallocate(pct_one)
               allocate(pct_one(size(area_one)))

               pct_one = sum(pct_pft_one,dim=1)
               pct_one = max(pct_one, 1.0e-6)

               lai_one = sum(lai_pft_one * pct_pft_one, dim=1) / pct_one
               LAI_patches(ipatch) = sum(lai_one * area_one) / sum(area_one)

               IF (patchtypes(landpatch%settyp(ipatch)) == 0) THEN
                  ipc = patch2pc(ipatch)
                  DO ipft = 0, N_PFT-1
                     sumarea = sum(pct_pft_one(ipft,:) * area_one)
                     IF (sumarea > 0) THEN
                        LAI_pcs(ipft,ipc) = sum(lai_pft_one(ipft,:) * pct_pft_one(ipft,:) * area_one) / sumarea
                     ELSE
                        LAI_pcs(ipft,ipc) = LAI_patches(ipatch)
                     ENDIF
                  ENDDO
               ENDIF
            ENDDO

#ifdef USEMPI
            CALL aggregation_worker_done ()
#endif
         ENDIF

      write(c2,'(i2.2)') month
#ifdef CoLMDEBUG
      CALL check_vector_data ('LAI_patches ' // trim(c2), LAI_patches)
      CALL check_vector_data ('LAI_pcs     ' // trim(c2), LAI_pcs   )
#endif
#ifdef USEMPI
         CALL mpi_barrier (p_comm_glb, p_err)
#endif

         ! ---------------------------------------------------
         ! write out the plant leaf area index of grid patches
         ! ---------------------------------------------------
#ifndef SinglePoint
         lndname = trim(landdir)//trim(cyear)//'/LAI_patches'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpatch)
         CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
         CALL ncio_write_vector (lndname, 'LAI_patches', 'patch', landpatch, LAI_patches, 1)

         lndname = trim(landdir)//trim(cyear)//'/LAI_pcs'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpc)
         CALL ncio_define_dimension_vector (lndname, landpc, 'pc')
         CALL ncio_define_dimension_vector (lndname, landpc, 'pft', N_PFT)
         CALL ncio_write_vector (lndname, 'LAI_pcs', 'pft', N_PFT, 'pc', landpc, LAI_pcs, 1)
#else
         SITE_LAI_pfts_clim(:,month) = LAI_pcs(:,1)
#endif
      ! loop end of month
      ENDDO

      ! IF (p_is_worker) THEN
      !    IF (allocated(LAI_patches)) deallocate(LAI_patches)
      !    IF (allocated(LAI_pcs    )) deallocate(LAI_pcs    )
      !    IF (allocated(lai_one    )) deallocate(lai_one    )
      !    IF (allocated(pct_one    )) deallocate(pct_one    )
      !    IF (allocated(pct_pft_one)) deallocate(pct_pft_one)
      !    IF (allocated(area_one   )) deallocate(area_one   )
      ! ENDIF

      DO month = 1, 12
         IF (p_is_io) THEN
            ! change var name to MONTHLY_PFT_SAI
            CALL read_5x5_data_pft_time (dir_5x5, suffix, gridlai, 'MONTHLY_PFT_SAI', month, pftLSAI)
#ifdef USEMPI
            CALL aggregation_data_daemon (gridlai, &
               data_r8_3d_in1 = pftPCT,  n1_r8_3d_in1 = 16, &
               data_r8_3d_in2 = pftLSAI, n1_r8_3d_in2 = 16)
#endif
         ENDIF

         ! ---------------------------------------------------------------
         ! aggregate the plant leaf area index from the resolution of raw data to modelling resolution
         ! ---------------------------------------------------------------

         IF (p_is_worker) THEN
            DO ipatch = 1, numpatch

               CALL aggregation_request_data (landpatch, ipatch, gridlai, area = area_one, &
                  data_r8_3d_in1 = pftPCT,  data_r8_3d_out1 = pct_pft_one, n1_r8_3d_in1 = 16, lb1_r8_3d_in1 = 0, &
                  data_r8_3d_in2 = pftLSAI, data_r8_3d_out2 = sai_pft_one, n1_r8_3d_in2 = 16, lb1_r8_3d_in2 = 0)

               IF (allocated(sai_one)) deallocate(sai_one)
               allocate(sai_one(size(area_one)))

               IF (allocated(pct_one)) deallocate(pct_one)
               allocate(pct_one(size(area_one)))

               pct_one = sum(pct_pft_one,dim=1)
               pct_one = max(pct_one, 1.0e-6)

               sai_one = sum(sai_pft_one * pct_pft_one, dim=1) / pct_one
               SAI_patches(ipatch) = sum(sai_one * area_one) / sum(area_one)

               IF (patchtypes(landpatch%settyp(ipatch)) == 0) THEN
                  ipc = patch2pc(ipatch)
                  DO ipft = 0, N_PFT-1
                     sumarea = sum(pct_pft_one(ipft,:) * area_one)
                     IF (sumarea > 0) THEN
                        SAI_pcs(ipft,ipc) = sum(sai_pft_one(ipft,:) * pct_pft_one(ipft,:) * area_one) / sumarea
                     ELSE
                        SAI_pcs(ipft,ipc) = SAI_patches(ipatch)
                     ENDIF
                  ENDDO
               ENDIF
            ENDDO

#ifdef USEMPI
            CALL aggregation_worker_done ()
#endif
         ENDIF

      write(c2,'(i2.2)') month
#ifdef CoLMDEBUG
      CALL check_vector_data ('SAI_patches ' // trim(c2), SAI_patches)
      CALL check_vector_data ('SAI_pcs     ' // trim(c2), SAI_pcs   )
#endif
#ifdef USEMPI
         CALL mpi_barrier (p_comm_glb, p_err)
#endif

         ! ---------------------------------------------------
         ! write out the plant stem area index of grid patches
         ! ---------------------------------------------------
#ifndef SinglePoint
         lndname = trim(landdir)//trim(cyear)//'/SAI_patches'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpatch)
         CALL ncio_define_dimension_vector (lndname, landpatch, 'patch')
         CALL ncio_write_vector (lndname, 'SAI_patches', 'patch', landpatch, SAI_patches, 1)

         lndname = trim(landdir)//trim(cyear)//'/SAI_pcs'//trim(c2)//'.nc'
         CALL ncio_create_file_vector (lndname, landpc)
         CALL ncio_define_dimension_vector (lndname, landpc, 'pc')
         CALL ncio_define_dimension_vector (lndname, landpc, 'pft', N_PFT)
         CALL ncio_write_vector (lndname, 'SAI_pcs', 'pft', N_PFT, 'pc', landpc, SAI_pcs, 1)
#else
         !TODO: single points
         SITE_SAI_pfts_clim(:,month) = SAI_pcs(:,1)
#endif
      ! loop end of month
      ENDDO
   ENDDO
   IF (p_is_worker) THEN
      IF (allocated(LAI_patches)) deallocate(LAI_patches)
      IF (allocated(LAI_pcs    )) deallocate(LAI_pcs    )
      IF (allocated(lai_one    )) deallocate(lai_one    )
      IF (allocated(SAI_patches)) deallocate(SAI_patches)
      IF (allocated(SAI_pcs    )) deallocate(SAI_pcs    )
      IF (allocated(sai_one    )) deallocate(sai_one    )
      IF (allocated(pct_one    )) deallocate(pct_one    )
      IF (allocated(pct_pft_one)) deallocate(pct_pft_one)
      IF (allocated(area_one   )) deallocate(area_one   )
   ENDIF
#endif

END SUBROUTINE Aggregation_LAI