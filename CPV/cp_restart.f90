!
! Copyright (C) 2005 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!------------------------------------------------------------------------------!
MODULE cp_restart
!------------------------------------------------------------------------------!
  !
  ! ... This module contains subroutines to write and read data required to
  ! ... restart a calculation from the disk  
  !
  USE xml_io_base
  !
  IMPLICIT NONE
  SAVE
  !
  PRIVATE :: write_wfc, read_wfc, read_cell
  !
  INTEGER, PARAMETER, PRIVATE :: iunout = 99
  !
!------------------------------------------------------------------------------!
  CONTAINS
!------------------------------------------------------------------------------!
  !
    SUBROUTINE cp_writefile( ndw, scradir, ascii, nfi, simtime, acc, nk, xk, wk, &
        ht, htm, htvel, gvel, xnhh0, xnhhm, vnhh, taui, cdmi, stau0, &
        svel0, staum, svelm, force, vnhp, xnhp0, xnhpm, nhpcl, occ0, &
        occm, lambda0, lambdam, xnhe0, xnhem, vnhe, ekincm, mat_z, et, &
        c04, cm4, c02, cm2 )
      !
      USE iotk_module
      USE kinds, ONLY: dbl
      USE io_global, ONLY: ionode, ionode_id, stdout
      USE control_flags, ONLY: gamma_only, force_pairing
      USE io_files, ONLY: iunpun, xmlpun, psfile, pseudo_dir, prefix
      USE printout_base, ONLY: title
      USE grid_dimensions, ONLY: nr1, nr2, nr3
      USE smooth_grid_dimensions, ONLY: nr1s, nr2s, nr3s
      USE smallbox_grid_dimensions, ONLY: nr1b, nr2b, nr3b
      USE gvecp, ONLY: ngm, ngmt, ecutp, gcutp
      USE gvecs, ONLY: ngs, ngst, ecuts, gcuts, dual
      USE gvecw, ONLY: ngw, ngwt, ecutw, gcutw
      USE reciprocal_vectors, ONLY: ig_l2g, mill_l
      USE electrons_base, ONLY: nspin, nbnd, nbsp, nelt, nel, nupdwn, iupdwn, &
                                f, fspin, nudx
      USE cell_base, ONLY: ibrav, alat, celldm, symm_type, s_to_r
      USE ions_base, ONLY: nsp, nat, na, atm, zv, pmass, amass, iforce
      USE funct,     ONLY: dft
      USE mp, ONLY: mp_sum
      USE parameters, ONLY: nhclm

      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ndw    !
      CHARACTER(LEN=*), INTENT(IN) :: scradir
      LOGICAL, INTENT(IN) :: ascii
      INTEGER, INTENT(IN) :: nfi    !  index of the current step
      REAL(dbl), INTENT(IN) :: simtime   !  simulated time
      REAL(dbl), INTENT(IN) :: acc(:)   !  
      INTEGER, INTENT(IN) :: nk    !  number of kpoints
      REAL(dbl), INTENT(IN) :: xk(:,:) ! k points coordinates 
      REAL(dbl), INTENT(IN) :: wk(:)   ! k points weights
      REAL(dbl), INTENT(IN) :: ht(3,3) ! 
      REAL(dbl), INTENT(IN) :: htm(3,3) ! 
      REAL(dbl), INTENT(IN) :: htvel(3,3) ! 
      REAL(dbl), INTENT(IN) :: gvel(3,3) ! 
      REAL(dbl), INTENT(IN) :: xnhh0(3,3) ! 
      REAL(dbl), INTENT(IN) :: xnhhm(3,3) ! 
      REAL(dbl), INTENT(IN) :: vnhh(3,3) ! 
      REAL(dbl), INTENT(IN) :: taui(:,:) ! 
      REAL(dbl), INTENT(IN) :: cdmi(:) ! 
      REAL(dbl), INTENT(IN) :: stau0(:,:) ! 
      REAL(dbl), INTENT(IN) :: svel0(:,:) ! 
      REAL(dbl), INTENT(IN) :: staum(:,:) ! 
      REAL(dbl), INTENT(IN) :: svelm(:,:) ! 
      REAL(dbl), INTENT(IN) :: force(:,:) ! 
      REAL(dbl), INTENT(IN) :: xnhp0(:)  ! 
      REAL(dbl), INTENT(IN) :: xnhpm(:)  ! 
      REAL(dbl), INTENT(IN) :: vnhp(:) ! 
      INTEGER,   INTENT(IN) :: nhpcl ! 
      REAL(dbl), INTENT(IN) :: occ0(:,:,:) ! 
      REAL(dbl), INTENT(IN) :: occm(:,:,:) ! 
      REAL(dbl), INTENT(IN) :: lambda0(:,:) ! 
      REAL(dbl), INTENT(IN) :: lambdam(:,:) ! 
      REAL(dbl), INTENT(IN) :: xnhe0 ! 
      REAL(dbl), INTENT(IN) :: xnhem ! 
      REAL(dbl), INTENT(IN) :: vnhe ! 
      REAL(dbl), INTENT(IN) :: ekincm ! 
      REAL(dbl), INTENT(IN) :: mat_z(:,:,:) ! 
      REAL(dbl), INTENT(IN) :: et(:,:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(IN) :: c04(:,:,:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(IN) :: cm4(:,:,:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(IN) :: c02(:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(IN) :: cm2(:,:) ! 
      !
      CHARACTER(LEN=256)      :: dirname, filename
      CHARACTER(iotk_attlenx) :: attr
      CHARACTER(LEN=4)        :: cspin
      INTEGER :: kunit, ib
      INTEGER :: k1, k2, k3
      INTEGER :: nk1, nk2, nk3
      INTEGER :: j, i, ispin, ig, nspin_wfc
      INTEGER :: is, ia, isa, iss, ise, ik
      INTEGER, ALLOCATABLE :: mill(:,:)
      INTEGER, ALLOCATABLE :: ftmp(:,:)
      INTEGER, ALLOCATABLE :: ityp(:)
      REAL(dbl), ALLOCATABLE :: tau(:,:)
      REAL(dbl) :: omega, htm1(3,3), h(3,3)
      REAL(dbl) :: a1(3), a2(3), a3(3)
      REAL(dbl) :: b1(3), b2(3), b3(3)
      LOGICAL   :: lsda

      !
      !  Create main restart directory
      !
      dirname = restart_dir( scradir, ndw )
      CALL create_directory( dirname )
      !
      !  Create K points subdirectories
      !  note: in FPMD and CP k points are not distributed to processors
      !
      DO i = 1, nk
        CALL create_directory( kpoint_dir( dirname, i ) )
      END DO

      !  Some ( CP/FPMD ) default values
      !
      kunit = 1
      k1 = 0
      k2 = 0
      k3 = 0
      nk1 = 1
      nk2 = 1
      nk3 = 1
      !
      !  Compute Cell related variables
      !
      h  = TRANSPOSE( ht )
      CALL invmat( 3, ht, htm1, omega )
      a1 = ht( 1, : )
      a2 = ht( 2, : )
      a3 = ht( 3, : )
      CALL recips( a1, a2, a3, b1, b2, b3 )
      !
      !  Compute array ityp, and tau
      !
      ALLOCATE( ityp( nat ) )
      ALLOCATE( tau( 3, nat ) )
      isa = 0
      DO is = 1, nsp
        DO ia = 1, na( is )
          isa = isa + 1
          ityp( isa ) = is
        END DO
      END DO
      call s_to_r( stau0, tau, na, nsp, h )

      !   
      !  Collect G vectors
      !   
      ALLOCATE( mill(3,ngmt) )
      mill = 0
      DO ig = 1, ngm
        mill(:,ig_l2g(ig)) = mill_l(:,ig)
      END DO
      CALL mp_sum( mill )


      lsda = ( nspin == 2 )

      ALLOCATE( ftmp( nudx, nspin ) )
      DO ispin = 1, nspin
        iss = iupdwn( ispin )
        ise = iss + nupdwn( ispin ) - 1
        ftmp( 1:nupdwn( ispin ), ispin ) = f( iss : ise )
      END DO
      !
      !  Open XML descriptor

      IF ( ionode ) THEN
        write(stdout,*) "Opening file "//trim(xmlpun)
        IF( ascii ) THEN
          call iotk_open_write(iunpun, &
               file=TRIM(dirname)//'/'//TRIM(xmlpun),binary=.false.)
        ELSE
          call iotk_open_write(iunpun, &
               file=TRIM(dirname)//'/'//TRIM(xmlpun),binary=.true.)
        ENDIF
      END IF
      !
      IF( ionode ) THEN
        !
        call iotk_write_begin(iunpun,"STATUS")
          call iotk_write_attr (attr,"nfi",nfi,first=.true.)
          call iotk_write_empty(iunpun,"STEP",attr)
          call iotk_write_dat (iunpun, "TIME", simtime)
          call iotk_write_dat (iunpun, "TITLE", TRIM(title) )
        call iotk_write_end(iunpun,"STATUS")      
        !
        ! ... CELL
        !
        CALL write_cell( ibrav, symm_type, &
                         celldm, alat, a1, a2, a3, b1, b2, b3 )
        ! 
        ! ... IONS
        !
        CALL write_ions( nsp, nat, atm, ityp, &
                         psfile, pseudo_dir, amass, tau, iforce, dirname )
        !
        ! ... PLANE_WAVES
        !
        CALL write_planewaves( ecutw, dual, ngwt, gamma_only, nr1, nr2, &
                               nr3, ngmt, nr1s, nr2s, nr3s, ngst, nr1b, &
                               nr2b, nr3b, mill, .FALSE. )
        !
        ! ... SPIN
        !
        CALL write_spin( lsda, .FALSE., 1, .FALSE. )
        !
        ! ... EXCHANGE_CORRELATION
        !
        CALL write_xc( DFT = dft, NSP = nsp, LDA_PLUS_U = .FALSE. )
        !
        ! ... OCCUPATIONS
        !
        CALL write_occ( LGAUSS = .FALSE., LTETRA = .FALSE., &
                        TFIXED_OCC = .TRUE., LSDA = lsda, NELUP = nupdwn(1), &
                        NELDW = nupdwn(2), F_INP = DBLE( ftmp ) )
        !
        ! ... BRILLOUIN_ZONE
        !
        CALL write_bz( nk, xk, wk )
        !
        ! ... PARALLELISM
        !
        CALL iotk_write_begin( iunpun, "PARALLELISM" )
          !
          CALL iotk_write_dat( iunpun, &
                               "GRANULARITY_OF_K-POINTS_DISTRIBUTION", kunit )
          !
        CALL iotk_write_end( iunpun, "PARALLELISM" )

        !
        ! ... CHARGE-DENSITY
        !
        CALL iotk_write_begin( iunpun, "CHARGE-DENSITY" )
        !
        CALL iotk_link( iunpun, "RHO_FILE", TRIM( prefix ) // ".rho", &
                        CREATE = .FALSE., BINARY = .TRUE., RAW = .TRUE. )
        !
        ! CALL iotk_write_begin( iunpun, "CHARGE-DENSITY", attr = attr )
        ! CALL iotk_write_dat( iunpun, "RHO", rho )
        ! CALL iotk_write_end( iunpun, "CHARGE-DENSITY" )
        !
        CALL iotk_write_end( iunpun, "CHARGE-DENSITY" )

        !
        call iotk_write_attr (attr, "nt", 2, first=.true.)
        call iotk_write_begin(iunpun,"TIMESTEPS", attr)
          !
          call iotk_write_begin(iunpun,"STEP0")
            !
            call iotk_write_dat (iunpun, "ACCUMULATORS", acc)
            !
            call iotk_write_begin(iunpun,"IONS_POSITIONS")
              call iotk_write_dat(iunpun, "stau", stau0(1:3,1:nat) )
              call iotk_write_dat(iunpun, "svel", svel0(1:3,1:nat) )
              call iotk_write_dat(iunpun, "taui", taui(1:3,1:nat) )
              call iotk_write_dat(iunpun, "cdmi", cdmi(1:3) )
              call iotk_write_dat(iunpun, "force", force(1:3,1:nat) )
            call iotk_write_end(iunpun,"IONS_POSITIONS")
            !
            call iotk_write_begin(iunpun,"IONS_NOSE")
              call iotk_write_dat (iunpun, "nhpcl", nhpcl)
              call iotk_write_dat (iunpun, "xnhp", xnhp0(1:nhclm) )
              call iotk_write_dat (iunpun, "vnhp", vnhp(1:nhclm) )
            call iotk_write_end(iunpun,"IONS_NOSE")
            !
            call iotk_write_dat (iunpun, "ekincm", ekincm)
            !
            call iotk_write_begin(iunpun,"ELECTRONS_NOSE")
              call iotk_write_dat (iunpun, "xnhe", xnhe0)
              call iotk_write_dat (iunpun, "vnhe", vnhe)
            call iotk_write_end(iunpun,"ELECTRONS_NOSE")
            !
            call iotk_write_begin(iunpun,"CELL_PARAMETERS")
              call iotk_write_dat (iunpun, "ht", ht)
              call iotk_write_dat (iunpun, "htvel", htvel)
              call iotk_write_dat (iunpun, "gvel", gvel)
            call iotk_write_end(iunpun,"CELL_PARAMETERS")
            !
            call iotk_write_begin(iunpun,"CELL_NOSE")
              call iotk_write_dat (iunpun, "xnhh", xnhh0)
              call iotk_write_dat (iunpun, "vnhh", vnhh)
            call iotk_write_end(iunpun,"CELL_NOSE")
            !
          call iotk_write_end(iunpun,"STEP0")
          !
          !
          call iotk_write_begin(iunpun,"STEPM")
            !
            call iotk_write_begin(iunpun,"IONS_POSITIONS")
              call iotk_write_dat(iunpun, "stau", staum(1:3,1:nat) )
              call iotk_write_dat(iunpun, "svel", svelm(1:3,1:nat) )
            call iotk_write_end(iunpun,"IONS_POSITIONS")
            !
            call iotk_write_begin(iunpun,"IONS_NOSE")
              call iotk_write_dat (iunpun, "nhpcl", nhpcl)
              call iotk_write_dat (iunpun, "xnhp", xnhpm(1:nhclm) )
              ! call iotk_write_dat (iunpun, "vnhp", vnhp)
            call iotk_write_end(iunpun,"IONS_NOSE")
            !
            call iotk_write_begin(iunpun,"ELECTRONS_NOSE")
              call iotk_write_dat (iunpun, "xnhe", xnhem)
              ! call iotk_write_dat (iunpun, "vnhe", vnhe)
            call iotk_write_end(iunpun,"ELECTRONS_NOSE")
            !
            call iotk_write_begin(iunpun,"CELL_PARAMETERS")
              call iotk_write_dat (iunpun, "ht", htm)
              ! call iotk_write_dat (iunpun, "htvel", htvel)
              ! call iotk_write_dat (iunpun, "gvel", gvel)
            call iotk_write_end(iunpun,"CELL_PARAMETERS")
            !
            call iotk_write_begin(iunpun,"CELL_NOSE")
              call iotk_write_dat (iunpun, "xnhh", xnhhm)
              ! call iotk_write_dat (iunpun, "vnhh", vnhh)
            call iotk_write_end(iunpun,"CELL_NOSE")
            !
          call iotk_write_end(iunpun,"STEPM")
          !
        call iotk_write_end(iunpun,"TIMESTEPS")
        !  
        ! ... BAND_STRUCTURE
        ! 
        CALL iotk_write_begin( iunpun, "BAND_STRUCTURE" )
        !
        CALL iotk_write_dat( iunpun, "NUMBER_OF_SPIN_COMPONENTS", nspin )
        !
        IF( nspin == 2 ) THEN
          call iotk_write_attr (attr,"up",nel(1),first=.true.)
          call iotk_write_attr (attr,"dw",nel(2))
          CALL iotk_write_dat( iunpun, "NUMBER_OF_ELECTRONS", nelt, ATTR = attr )
        ELSE
          CALL iotk_write_dat( iunpun, "NUMBER_OF_ELECTRONS", nelt )
        END IF
        !
        IF( nspin == 2 ) THEN
          call iotk_write_attr (attr,"up",nupdwn(1),first=.true.)
          call iotk_write_attr (attr,"dw",nupdwn(2))
          CALL iotk_write_dat( iunpun, "NUMBER_OF_BANDS", nbnd, ATTR = attr )
        ELSE
	  CALL iotk_write_dat( iunpun, "NUMBER_OF_BANDS", nbnd )
        END IF
        !
        CALL iotk_write_begin( iunpun, "EIGENVALUES_AND_EIGENVECTORS" )
        !
      END IF

      k_points_loop: DO ik = 1, nk
         !
         IF ( ionode ) THEN
            !
            CALL iotk_write_begin( iunpun, "K-POINT" // TRIM( iotk_index(ik) ) )
            !
            CALL iotk_write_attr( attr, "UNIT", "2 pi / a", FIRST = .TRUE. )
            CALL iotk_write_dat( iunpun, "K-POINT_COORDS", xk(:,ik), ATTR = attr )
            !
            CALL iotk_write_dat( iunpun, "WEIGHT", wk(ik) )

            DO ispin = 1, nspin
               !
               cspin = iotk_index(ispin)
               !
               CALL iotk_write_attr( attr, "UNIT", "Hartree", FIRST = .TRUE. )
               CALL iotk_write_dat( iunpun, "ET" // TRIM( cspin ), et(:, ik, ispin), ATTR = attr  )
               !
               CALL iotk_write_dat( iunpun, "OCC"  // TRIM( cspin ),  occ0(:, ik, ispin ) )
               CALL iotk_write_dat( iunpun, "OCCM" // TRIM( cspin ),  occm(:, ik, ispin ) )
               !
            END DO
            !
            ! ... G+K vectors
            !
            filename = TRIM( wfc_filename( ".", 'gkvectors', ik ) )
            !
            CALL iotk_link( iunpun, "gkvectors", filename, &
                            CREATE = .FALSE., BINARY = .TRUE., RAW = .TRUE. )
            !
            filename = TRIM( wfc_filename( dirname, 'gkvectors', ik ) )
            !
         END IF


         DO ispin = 1, nspin
            ! 
            IF ( ionode ) THEN
               !
               filename = TRIM( wfc_filename( ".", 'evc', ik, ispin ) )
               !
               CALL iotk_link( iunpun, "wfc", filename, &
                               CREATE = .FALSE., BINARY = .TRUE., RAW = .TRUE. )
               !
               filename = TRIM( wfc_filename( dirname, 'evc', ik, ispin ) )

            END IF

            IF( PRESENT( C04 ) ) THEN
              CALL write_wfc( iunout, ik, nk, kunit, ispin, nspin, &
                            c04(:,:,ik,ispin), ngwt, nbnd, ig_l2g,   &
                            ngw, filename )
            ELSE IF( PRESENT( C02 ) ) THEN
              ib = iupdwn(ispin)
              CALL write_wfc( iunout, ik, nk, kunit, ispin, nspin, &
                            c02(:,ib:), ngwt, nbnd, ig_l2g,   &
                            ngw, filename )
            END IF

            IF ( ionode ) THEN
               !
               filename = TRIM( wfc_filename( ".", 'evcm', ik, ispin ) )
               !
               CALL iotk_link( iunpun, "wfcm", filename, &
                               CREATE = .FALSE., BINARY = .TRUE., RAW = .TRUE. )
               !
               filename = TRIM( wfc_filename( dirname, 'evcm', ik, ispin ) )

            END IF

            IF( PRESENT( cm4 ) ) THEN
              CALL write_wfc( iunout, ik, nk, kunit, ispin, nspin, &
                            cm4(:,:,ik,ispin), ngwt, nbnd, ig_l2g,  &
                            ngw, filename )
            ELSE IF( PRESENT( c02 ) ) THEN
              ib = iupdwn(ispin)
              CALL write_wfc( iunout, ik, nk, kunit, ispin, nspin, &
                            cm2(:,ib:), ngwt, nbnd, ig_l2g,  &
                            ngw, filename )
            END IF

            !
         END DO
         !
         IF ( ionode ) THEN
            !
            CALL iotk_write_end( iunpun, "K-POINT" // TRIM( iotk_index(ik) ) )
            !
         END IF
         !
      END DO k_points_loop
      !
      DO ispin = 1, nspin
         ! 
         cspin = iotk_index(ispin)
         !
         IF ( ionode ) THEN
            ! 
            filename = 'mat_z' // cspin
            call iotk_link(iunpun,"mat_z" // TRIM( cspin ), filename,create=.true.,binary=.true.,raw=.true.)
            call iotk_write_dat(iunpun,"mat_z" // TRIM( cspin ), mat_z(:,:,ispin) )
            !
         END IF
         !
      END DO

      IF( ionode ) THEN
        !  
        CALL iotk_write_end( iunpun, "EIGENVALUES_AND_EIGENVECTORS" )
        !     
        CALL iotk_write_end( iunpun, "BAND_STRUCTURE" )
        ! 
      END IF


      !
      !  Write matrix lambda to file
      !
      filename = TRIM( dirname ) // '/lambda.dat'
      IF( ionode ) THEN
        OPEN( unit = 10, file = TRIM(filename), status = 'UNKNOWN', form = 'UNFORMATTED' )
        WRITE( 10 ) lambda0
        WRITE( 10 ) lambdam
        CLOSE( unit = 10 )
      END IF

      if( ionode ) then
        call iotk_close_write( iunpun )
      end if 

      DEALLOCATE( ftmp )
      DEALLOCATE( tau  )
      DEALLOCATE( ityp )
      DEALLOCATE( mill )

      RETURN
    END SUBROUTINE cp_writefile


!=-----------------------------------------------------------------------------=!


    SUBROUTINE cp_readfile( ndr, scradir, ascii, nfi, simtime, acc, nk, xk, wk, &
        ht, htm, htvel, gvel, xnhh0, xnhhm, vnhh, taui, cdmi, stau0, &
        svel0, staum, svelm, force, vnhp, xnhp0, xnhpm, nhpcl, &
        occ0, occm, lambda0, lambdam, b1, b2, b3, xnhe0, xnhem, &
        vnhe, ekincm, mat_z, tens, c04, cm4, c02, cm2 )
      !
      USE iotk_module
      USE kinds, ONLY: dbl
      USE io_global, ONLY: ionode, ionode_id, stdout
      USE parser, ONLY: int_to_char
      USE control_flags, ONLY: gamma_only, force_pairing
      USE io_files, ONLY: iunpun, xmlpun
      USE printout_base, ONLY: title
      USE grid_dimensions, ONLY: nr1, nr2, nr3
      USE smooth_grid_dimensions, ONLY: nr1s, nr2s, nr3s
      USE smallbox_grid_dimensions, ONLY: nr1b, nr2b, nr3b
      USE gvecp, ONLY: ngm, ngmt, ecutp
      USE gvecs, ONLY: ngs, ngst
      USE gvecw, ONLY: ngw, ngwt, ecutw
      USE electrons_base, ONLY: nspin, nbnd, nelt, nel, nupdwn, iupdwn
      USE cell_base, ONLY: ibrav, alat, celldm, symm_type
      USE ions_base, ONLY: nsp, nat, na, atm, zv, pmass
      USE reciprocal_vectors, ONLY: ngwt, ngw, ig_l2g, mill_l
      USE mp, ONLY: mp_sum, mp_bcast
      USE parameters, ONLY: nhclm

      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ndr    !  I/O unit number
      CHARACTER(LEN=*), INTENT(IN) :: scradir
      LOGICAL, INTENT(IN) :: ascii
      INTEGER, INTENT(INOUT) :: nfi    !  index of the current step
      REAL(dbl), INTENT(INOUT) :: simtime   !  simulated time
      REAL(dbl), INTENT(INOUT) :: acc(:)   !
      INTEGER, INTENT(IN) :: nk    !  number of kpoints
      REAL(dbl), INTENT(INOUT) :: xk(:,:) ! k points coordinates
      REAL(dbl), INTENT(INOUT) :: wk(:)   ! k points weights
      REAL(dbl), INTENT(INOUT) :: ht(3,3) !
      REAL(dbl), INTENT(INOUT) :: htm(3,3) !
      REAL(dbl), INTENT(INOUT) :: htvel(3,3) !
      REAL(dbl), INTENT(INOUT) :: gvel(3,3) !
      REAL(dbl), INTENT(INOUT) :: xnhh0(3,3) !
      REAL(dbl), INTENT(INOUT) :: xnhhm(3,3) !
      REAL(dbl), INTENT(INOUT) :: vnhh(3,3) !
      REAL(dbl), INTENT(INOUT) :: taui(:,:) !
      REAL(dbl), INTENT(INOUT) :: cdmi(:) !
      REAL(dbl), INTENT(INOUT) :: stau0(:,:) !
      REAL(dbl), INTENT(INOUT) :: svel0(:,:) !
      REAL(dbl), INTENT(INOUT) :: staum(:,:) !
      REAL(dbl), INTENT(INOUT) :: svelm(:,:) !
      REAL(dbl), INTENT(INOUT) :: force(:,:) ! 
      REAL(dbl), INTENT(INOUT) :: xnhp0(:) !     
      REAL(dbl), INTENT(INOUT) :: xnhpm(:) ! 
      REAL(dbl), INTENT(INOUT) :: vnhp(:) !  
      INTEGER,   INTENT(INOUT) :: nhpcl !  
      REAL(dbl), INTENT(INOUT) :: occ0(:,:,:) !
      REAL(dbl), INTENT(INOUT) :: occm(:,:,:) !
      REAL(dbl), INTENT(INOUT) :: lambda0(:,:) !
      REAL(dbl), INTENT(INOUT) :: lambdam(:,:) !
      REAL(dbl), INTENT(INOUT) :: b1(3) !
      REAL(dbl), INTENT(INOUT) :: b2(3) !
      REAL(dbl), INTENT(INOUT) :: b3(3) !
      REAL(dbl), INTENT(INOUT) :: xnhe0 !
      REAL(dbl), INTENT(INOUT) :: xnhem !
      REAL(dbl), INTENT(INOUT) :: vnhe !  
      REAL(dbl), INTENT(INOUT) :: ekincm !  
      REAL(dbl), INTENT(INOUT) :: mat_z(:,:,:) ! 
      LOGICAL, INTENT(IN) :: tens
      COMPLEX(dbl), OPTIONAL, INTENT(INOUT) :: c04(:,:,:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(INOUT) :: cm4(:,:,:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(INOUT) :: c02(:,:) ! 
      COMPLEX(dbl), OPTIONAL, INTENT(INOUT) :: cm2(:,:) ! 

      !
      CHARACTER(LEN=256) :: dirname, kdirname, filename
      CHARACTER(LEN=5)   :: kindex
      CHARACTER(LEN=4)   :: cspin
      INTEGER :: strlen
      CHARACTER(iotk_attlenx) :: attr
      INTEGER :: kunit
      INTEGER :: k1, k2, k3
      INTEGER :: nk1, nk2, nk3
      INTEGER :: i, j, ispin, ig, nspin_wfc, ierr, ik
      INTEGER, ALLOCATABLE :: mill(:,:)
      REAL(dbl) :: omega, htm1(3,3)
      !
      ! Variables read for testing pourposes
      !
      INTEGER :: ibrav_
      CHARACTER(LEN=256) :: symm_type_
      INTEGER :: nat_ , nsp_, na_
      INTEGER :: nk_ , ik_ , nt_
      LOGICAL :: gamma_only_ , found
      REAL(dbl) :: alat_ , a1_ (3), a2_ (3), a3_ (3)
      REAL(dbl) :: pmass_ , zv_
      REAL(dbl) :: celldm_ ( 6 )
      INTEGER :: ispin_ , nspin_ , ngwt_ , nbnd_ , nelt_
      INTEGER :: nhpcl_ 
      INTEGER :: ib 

      kunit = 1

      dirname = restart_dir( scradir, ndr )
      filename = TRIM( dirname ) // '/' // 'restart.xml'
     
      IF( ionode ) THEN
        CALL iotk_open_read( iunpun, file = TRIM( filename ), binary = .FALSE., root = attr )
      END IF

      ierr = 0
      IF( ionode ) THEN
        !
        call iotk_scan_begin(iunpun,"STATUS" )
        call iotk_scan_empty(iunpun,"STEP",attr)
        call iotk_scan_attr (attr,"nfi",nfi)
        call iotk_scan_dat (iunpun, "TIME", simtime )
        call iotk_scan_dat (iunpun, "TITLE", title )
        call iotk_scan_end(iunpun,"STATUS")
        !
        call read_cell( ibrav_ , symm_type_ , celldm_ , alat_ , &
                        a1_ , a2_ , a3_ , b1, b2, b3 )
        !
        call iotk_scan_begin(iunpun,"IONS")
          call iotk_scan_dat ( iunpun, "NUMBER_OF_ATOMS", nat_ )
          call iotk_scan_dat ( iunpun, "NUMBER_OF_SPECIES", nsp_ )
          IF( nsp_ /= nsp .OR. nat_ /= nat ) THEN 
            ierr = 10
            GOTO 100
          END IF
        call iotk_scan_end(iunpun,"IONS")
        !
        ! 
        !
        call iotk_scan_begin(iunpun,"TIMESTEPS", attr)
        call iotk_scan_attr (attr, "nt", nt_ )

          !
          IF( nt_ > 0 ) THEN
            !
            call iotk_scan_begin(iunpun,"STEP0")
              !
              call iotk_scan_dat (iunpun, "ACCUMULATORS", acc)
              !
              call iotk_scan_begin(iunpun,"IONS_POSITIONS")
                call iotk_scan_dat(iunpun, "stau", stau0(1:3,1:nat) )
                call iotk_scan_dat(iunpun, "svel", svel0(1:3,1:nat) )
                call iotk_scan_dat(iunpun, "taui", taui(1:3,1:nat) )
                call iotk_scan_dat(iunpun, "cdmi", cdmi(1:3) )
                call iotk_scan_dat(iunpun, "force", force(1:3,1:nat) )
              call iotk_scan_end(iunpun,"IONS_POSITIONS")
              !
              call iotk_scan_begin(iunpun,"IONS_NOSE")
                call iotk_scan_dat (iunpun, "nhpcl", nhpcl_ )
                call iotk_scan_dat (iunpun, "xnhp", xnhp0(1:nhclm) )
                call iotk_scan_dat (iunpun, "vnhp", vnhp(1:nhclm) )
              call iotk_scan_end(iunpun,"IONS_NOSE")
              !
              call iotk_scan_dat (iunpun, "ekincm", ekincm)
              !
              call iotk_scan_begin(iunpun,"ELECTRONS_NOSE")
                call iotk_scan_dat (iunpun, "xnhe", xnhe0)
                call iotk_scan_dat (iunpun, "vnhe", vnhe)
              call iotk_scan_end(iunpun,"ELECTRONS_NOSE")
              !
              call iotk_scan_begin(iunpun,"CELL_PARAMETERS")
                call iotk_scan_dat (iunpun, "ht", ht)
                call iotk_scan_dat (iunpun, "htvel", htvel)
                call iotk_scan_dat (iunpun, "gvel", gvel )
              call iotk_scan_end(iunpun,"CELL_PARAMETERS")
              !
              call iotk_scan_begin(iunpun,"CELL_NOSE")
                call iotk_scan_dat (iunpun, "xnhh", xnhh0)
                call iotk_scan_dat (iunpun, "vnhh", vnhh)
              call iotk_scan_end(iunpun,"CELL_NOSE")
              !
            call iotk_scan_end(iunpun,"STEP0")

            !
          ELSE
            ierr = 40
            GOTO 100
          END IF
         
          IF( nt_ > 1 ) THEN
            !
            call iotk_scan_begin(iunpun,"STEPM")
              !
              call iotk_scan_begin(iunpun,"IONS_POSITIONS")
                call iotk_scan_dat(iunpun, "stau", staum(1:3,1:nat) )
                call iotk_scan_dat(iunpun, "svel", svelm(1:3,1:nat) )
              call iotk_scan_end(iunpun,"IONS_POSITIONS")
              !
              call iotk_scan_begin(iunpun,"IONS_NOSE")
                call iotk_scan_dat (iunpun, "nhpcl", nhpcl_ )
                call iotk_scan_dat (iunpun, "xnhp", xnhpm(1:nhclm) )
              call iotk_scan_end(iunpun,"IONS_NOSE")
              !
              call iotk_scan_begin(iunpun,"ELECTRONS_NOSE")
                call iotk_scan_dat (iunpun, "xnhe", xnhem)
              call iotk_scan_end(iunpun,"ELECTRONS_NOSE")
              !
              call iotk_scan_begin(iunpun,"CELL_PARAMETERS")
                call iotk_scan_dat (iunpun, "ht", htm)
                ! call iotk_scan_dat (iunpun, "htvel", htvel)
                ! call iotk_scan_dat (iunpun, "gvel", gvel, FOUND=found, IERR=ierr )
                ! if ( .NOT. found ) gvel = 0.0d0
              call iotk_scan_end(iunpun,"CELL_PARAMETERS")
              !
              call iotk_scan_begin(iunpun,"CELL_NOSE")
                call iotk_scan_dat (iunpun, "xnhh", xnhhm)
              call iotk_scan_end(iunpun,"CELL_NOSE")
              !
            call iotk_scan_end(iunpun,"STEPM")

            !
          END IF
          !
        call iotk_scan_end(iunpun,"TIMESTEPS")
        !
      END IF   !  ionode

      ! 
      !  Band Structure
      !

      IF( ionode ) THEN

        call iotk_scan_begin( iunpun, "BAND_STRUCTURE" )
          !
          call iotk_scan_dat( iunpun, "NUMBER_OF_SPIN_COMPONENTS", nspin_ )
          !
          IF( nspin_ == 2 ) THEN
            call iotk_scan_dat( iunpun, "NUMBER_OF_ELECTRONS", nelt_ , ATTR = attr)
            call iotk_scan_dat( iunpun, "NUMBER_OF_BANDS", nbnd_ , ATTR = attr)
          ELSE
            call iotk_scan_dat( iunpun, "NUMBER_OF_ELECTRONS", nelt_ )
            call iotk_scan_dat( iunpun, "NUMBER_OF_BANDS", nbnd_ )
          END IF

          IF( ( nspin_ /= nspin ) .OR. ( nbnd_ /= nbnd ) .OR. ( nelt_ /= nelt ) ) THEN 
            ierr = 30
            GOTO 100
          END IF
          ! 

          CALL iotk_scan_begin( iunpun, "EIGENVALUES_AND_EIGENVECTORS" )

      END IF   !  ionode


      k_points_loop: DO ik = 1, nk
        !
        IF ( ionode ) THEN
          CALL iotk_scan_begin( iunpun, "K-POINT" // TRIM( iotk_index(ik) ) )
        END IF
        !
        DO ispin = 1, nspin
          !
          cspin = iotk_index( ispin )
          !
          IF( ionode ) THEN
            CALL iotk_scan_dat( iunpun, "OCC"  // TRIM( cspin ),  occ0(:, ik, ispin ) )
            CALL iotk_scan_dat( iunpun, "OCCM" // TRIM( cspin ),  occm(:, ik, ispin ), FOUND=found, IERR=ierr )
            IF ( .NOT. found ) occm(:, ik, ispin ) = occ0(:, ik, ispin )
          END IF

          IF ( ionode ) THEN
             !
             filename = TRIM( wfc_filename( dirname, 'evc', ik, ispin ) )
             !
          END IF
          !
          IF( PRESENT( c04 ) ) THEN
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         c04(:,:,ik,ispin), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
          ELSE IF( PRESENT( c02 ) ) THEN
            ib = iupdwn(ispin)
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         c02( :, ib: ), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
          END IF

          IF ( ionode ) THEN
             !
             filename = TRIM( wfc_filename( dirname, 'evcm', ik, ispin ) )
             !
          END IF
          !
          IF( PRESENT( cm4 ) ) THEN
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         cm4(:,:,ik,ispin), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
          ELSE IF( PRESENT( cm2 ) ) THEN
            ib = iupdwn(ispin)
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         cm2( :, ib: ), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
          END IF

          !
        END DO
        !
        IF ( ionode ) THEN
          CALL iotk_scan_end( iunpun, "K-POINT" // TRIM( iotk_index(ik) ) )
        END IF
        !
      END DO k_points_loop


      DO ispin = 1, nspin
        IF( ionode .AND. tens ) THEN
          call iotk_scan_dat( iunpun, "mat_z" // TRIM( iotk_index(ispin) ), mat_z(:,:,ispin) )
        END IF
      END DO

      IF( ionode ) THEN

          CALL iotk_scan_end( iunpun, "EIGENVALUES_AND_EIGENVECTORS" )

        call iotk_scan_end( iunpun,"BAND_STRUCTURE")

      END IF   !  ionode

      !
      !
 100  CONTINUE
      !
      CALL mp_bcast( ierr, ionode_id )
      CALL mp_bcast( attr, ionode_id )
      IF( ierr /= 0 ) THEN
        CALL errore( " cp_readfile ", TRIM( attr ), ierr )
      END IF
      !
      CALL mp_bcast( nfi, ionode_id )
      CALL mp_bcast( simtime, ionode_id )
      CALL mp_bcast( title, ionode_id )
      CALL mp_bcast( acc, ionode_id )
      !
      CALL mp_bcast( ht, ionode_id )
      CALL mp_bcast( htm, ionode_id )
      CALL mp_bcast( htvel, ionode_id )
      CALL mp_bcast( gvel, ionode_id )
      CALL mp_bcast( xnhh0, ionode_id )
      CALL mp_bcast( xnhhm, ionode_id )
      CALL mp_bcast( vnhh, ionode_id )
      CALL mp_bcast( b1, ionode_id )
      CALL mp_bcast( b2, ionode_id )
      CALL mp_bcast( b3, ionode_id )
      !
      CALL mp_bcast(stau0, ionode_id)
      CALL mp_bcast(svel0, ionode_id)
      CALL mp_bcast(staum, ionode_id)
      CALL mp_bcast(svelm, ionode_id)
      CALL mp_bcast(taui, ionode_id)
      CALL mp_bcast(force, ionode_id)
      CALL mp_bcast(cdmi, ionode_id)
      CALL mp_bcast(xnhp0, ionode_id)
      CALL mp_bcast(xnhpm, ionode_id)
      CALL mp_bcast(vnhp, ionode_id)
      !
      CALL mp_bcast(xnhe0, ionode_id)
      CALL mp_bcast(xnhem, ionode_id)
      CALL mp_bcast(vnhe, ionode_id)
      !
      CALL mp_bcast(kunit, ionode_id)

      CALL mp_bcast(occ0( :, :, :), ionode_id)
      CALL mp_bcast(occm( :, :, :), ionode_id)
      !
      IF( tens ) THEN
        CALL mp_bcast(mat_z( :, :, :), ionode_id)
      END IF
      !

      IF( ionode ) THEN
        CALL iotk_close_read( iunpun )
      END IF

      !
      !  Read matrix lambda to file
      !
      filename = TRIM( dirname ) // '/lambda.dat'
      IF( ionode ) THEN
        OPEN( unit = 10, file = TRIM(filename), status = 'OLD', form = 'UNFORMATTED' )
        READ( 10 ) lambda0
        READ( 10 ) lambdam
        CLOSE( unit = 10 )
      END IF
      CALL mp_bcast(lambda0, ionode_id)
      CALL mp_bcast(lambdam, ionode_id)


      RETURN
    END SUBROUTINE cp_readfile

!=-----------------------------------------------------------------------------=!

    SUBROUTINE cp_read_wfc( ndr, scradir, ik, nk, ispin, nspin, c2, c4, tag )
      !
      USE kinds, ONLY: dbl
      USE io_global, ONLY: ionode, ionode_id, stdout
      USE electrons_base, ONLY: nbnd, iupdwn
      USE reciprocal_vectors, ONLY: ngwt, ngw, ig_l2g

      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ndr
      CHARACTER(LEN=*), INTENT(IN) :: scradir
      CHARACTER, INTENT(IN) :: tag
      COMPLEX(dbl), OPTIONAL, INTENT(OUT) :: c2(:,:) !
      COMPLEX(dbl), OPTIONAL, INTENT(OUT) :: c4(:,:,:,:) !
      INTEGER, INTENT(IN) :: ik, ispin, nk, nspin
      !
      CHARACTER(LEN=256) :: dirname, filename
      INTEGER :: ib, kunit , ispin_ , nspin_ , ngwt_ , nbnd_
      !
      kunit = 1
      !
      dirname  = restart_dir( scradir, ndr )
      IF( tag /= 'm' ) THEN
        filename = TRIM( wfc_filename( dirname, 'evc', ik, ispin ) )
      ELSE
        filename = TRIM( wfc_filename( dirname, 'evcm', ik, ispin ) )
      END IF
      !
      IF( PRESENT( c4 ) ) THEN
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         c4(:,:,ik,ispin), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
      ELSE IF( PRESENT( c2 ) ) THEN
            ib = iupdwn(ispin)
            CALL read_wfc( iunout, ik, nk, kunit, ispin_ , nspin_ , &
                         c2( :, ib: ), ngwt_ , nbnd_ , ig_l2g,       &
                         ngw, filename )
      END IF
      !
      RETURN
    END SUBROUTINE cp_read_wfc

!=----------------------------------=!

    SUBROUTINE cp_read_cell &
      ( ndr, scradir, ascii, ht, htm, htvel, gvel, xnhh0, xnhhm, vnhh )
      !
      USE iotk_module
      USE kinds, ONLY: dbl
      USE io_global, ONLY: ionode, ionode_id, stdout
      USE parser, ONLY: int_to_char
      USE io_files, ONLY: iunpun, xmlpun
      USE mp, ONLY: mp_sum, mp_bcast

      IMPLICIT NONE
      INTEGER, INTENT(IN) :: ndr
      CHARACTER(LEN=*), INTENT(IN) :: scradir
      LOGICAL, INTENT(IN) :: ascii
      REAL(dbl), INTENT(INOUT) :: ht(3,3) !
      REAL(dbl), INTENT(INOUT) :: htm(3,3) !
      REAL(dbl), INTENT(INOUT) :: htvel(3,3) !
      REAL(dbl), INTENT(INOUT) :: gvel(3,3) !
      REAL(dbl), INTENT(INOUT) :: xnhh0(3,3) !
      REAL(dbl), INTENT(INOUT) :: xnhhm(3,3) !
      REAL(dbl), INTENT(INOUT) :: vnhh(3,3) !
      !
      CHARACTER(LEN=256) :: dirname, filename
      INTEGER :: strlen
      CHARACTER(iotk_attlenx) :: attr
      INTEGER :: i, ierr, nt_
      LOGICAL :: found
      !
      ! Variables read for testing pourposes
      !
      INTEGER :: ibrav_
      REAL(dbl) :: alat_
      REAL(dbl) :: celldm_ ( 6 )

      dirname  = restart_dir( scradir, ndr ) 
      filename = TRIM( dirname ) // '/' // 'restart.xml'
     
      IF( ionode ) THEN
        CALL iotk_open_read( iunpun, file = TRIM( filename ), binary = .FALSE., root = attr )
      END IF

      ierr = 0
      IF( ionode ) THEN
        !
        call iotk_scan_begin(iunpun,"TIMESTEPS", attr)
        call iotk_scan_attr (attr, "nt", nt_ )
          !
          IF( nt_ > 0 ) THEN
            !
            call iotk_scan_begin(iunpun,"STEP0")
              !
              call iotk_scan_begin(iunpun,"CELL_PARAMETERS")
                call iotk_scan_dat (iunpun, "ht", ht)
                call iotk_scan_dat (iunpun, "htvel", htvel)
                call iotk_scan_dat (iunpun, "gvel", gvel, FOUND=found, IERR=ierr )
                if ( .NOT. found ) gvel = 0.0d0
              call iotk_scan_end(iunpun,"CELL_PARAMETERS")
              !
              call iotk_scan_begin(iunpun,"CELL_NOSE")
                call iotk_scan_dat (iunpun, "xnhh", xnhh0)
                call iotk_scan_dat (iunpun, "vnhh", vnhh)
              call iotk_scan_end(iunpun,"CELL_NOSE")
              !
            call iotk_scan_end(iunpun,"STEP0")
            !
          ELSE
            ierr = 40
            GOTO 100
          END IF
         
          IF( nt_ > 1 ) THEN
            !
            call iotk_scan_begin(iunpun,"STEPM")
              !
              call iotk_scan_begin(iunpun,"CELL_PARAMETERS")
                call iotk_scan_dat (iunpun, "ht", htm)
              call iotk_scan_end(iunpun,"CELL_PARAMETERS")
              !
              call iotk_scan_begin(iunpun,"CELL_NOSE")
                call iotk_scan_dat (iunpun, "xnhh", xnhhm)
              call iotk_scan_end(iunpun,"CELL_NOSE")
              !
            call iotk_scan_end(iunpun,"STEPM")
            !
          END IF
          !
        call iotk_scan_end(iunpun,"TIMESTEPS")
        !
      END IF
      !
 100  CONTINUE
      !
      CALL mp_bcast( ierr, ionode_id )
      CALL mp_bcast( attr, ionode_id )
      IF( ierr /= 0 ) THEN
        CALL errore( " cp_readfile ", attr, ierr )
      END IF
      !
      CALL mp_bcast( ht, ionode_id )
      CALL mp_bcast( htm, ionode_id )
      CALL mp_bcast( htvel, ionode_id )
      CALL mp_bcast( gvel, ionode_id )
      CALL mp_bcast( xnhh0, ionode_id )
      CALL mp_bcast( xnhhm, ionode_id )
      CALL mp_bcast( vnhh, ionode_id )
      !
      IF( ionode ) THEN
        CALL iotk_close_read( iunpun )
      END IF

      RETURN
    END SUBROUTINE cp_read_cell

!
!
!=----------------------------------------------------------------------------=!

!
! ..  This subroutine write wavefunctions to the disk
!

    SUBROUTINE write_wfc(iuni, ik, nk, kunit, ispin, nspin, wf, ngw, nbnd, igl, ngwl, filename )
!
      USE kinds, ONLY: dbl
      USE mp_wave
      USE mp,        ONLY: mp_sum, mp_get, mp_bcast, mp_max
      USE mp_global, ONLY: mpime, nproc, root, me_pool, my_pool_id, &
                           nproc_pool, intra_pool_comm, root_pool, my_image_id
      USE io_global, ONLY: ionode, ionode_id
      USE iotk_module
!
      IMPLICIT NONE
!
      INTEGER, INTENT(IN) :: iuni
      INTEGER, INTENT(IN) :: ik, nk, kunit, ispin, nspin
      COMPLEX(dbl), INTENT(IN) :: wf(:,:)
      INTEGER, INTENT(IN) :: ngw   ! 
      INTEGER, INTENT(IN) :: nbnd
      INTEGER, INTENT(IN) :: ngwl
      INTEGER, INTENT(IN) :: igl(:)
      CHARACTER(LEN=256), INTENT(IN) :: filename

      INTEGER :: i, j, ierr
      INTEGER :: nkl, nkr, nkbl, iks, ike, nkt, ikt, igwx
      INTEGER :: npool, ipmask( nproc ), ipsour
      COMPLEX(dbl), ALLOCATABLE :: wtmp(:)
      INTEGER, ALLOCATABLE :: igltot(:)
      INTEGER                       :: ierr_iotk
      CHARACTER(LEN=iotk_attlenx)   :: attr


      ! set working variables for k point index (ikt) and k points number (nkt)

      ikt = ik
      nkt = nk

      !  find out the number of pools

      npool = nproc / nproc_pool 

      !  find out number of k points blocks

      nkbl = nkt / kunit  

      !  k points per pool
      nkl = kunit * ( nkbl / npool )

      !  find out the reminder
      nkr = ( nkt - nkl * npool ) / kunit

      !  Assign the reminder to the first nkr pools
      IF( my_pool_id < nkr ) nkl = nkl + kunit

      !  find out the index of the first k point in this pool
      iks = nkl * my_pool_id + 1
      IF( my_pool_id >= nkr ) iks = iks + nkr * kunit
      
      !  find out the index of the last k point in this pool
      ike = iks + nkl - 1

      ipmask = 0
      ipsour = ionode_id

      !  find out the index of the processor which collect the data in the pool of ik
      !
      IF( npool > 1 ) THEN
        IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
          IF( me_pool == root_pool ) ipmask( mpime + 1 ) = 1
        END IF
        CALL mp_sum( ipmask )
        DO i = 1, nproc
          IF( ipmask(i) == 1 ) ipsour = ( i - 1 )
        END DO
      END IF

      igwx = 0
      ierr = 0
      IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
        IF( ngwl > SIZE( igl ) ) THEN
          ierr = 1
        ELSE
          igwx = MAXVAL( igl(1:ngwl) )
        END IF
      END IF

      ! get the maximum G vector index within the pool
      !
      CALL mp_max( igwx, intra_pool_comm ) 

      ! now notify all procs if an error has been found 
      !
      CALL mp_max( ierr ) 

      IF( ierr > 0 ) &
        CALL errore(' write_wfc ',' wrong size ngl ', ierr )

      IF( ipsour /= ionode_id ) THEN
        CALL mp_get( igwx, igwx, mpime, ionode_id, ipsour, 1 )
      END IF

      ! IF( ionode ) WRITE(iuni) ngw, nbnd, ik, nk, kunit, ispin, nspin
      ! IF( ionode ) WRITE(iuni) igwx

      IF( ionode ) THEN
         !
         CALL iotk_open_write( iuni, FILE = TRIM( filename ), BINARY = .TRUE. )
         !
         CALL iotk_write_begin( iuni, "K-POINT" // iotk_index( ik ) )
         !
         CALL iotk_write_attr( attr, "ngw",   ngw, FIRST = .TRUE. )
         CALL iotk_write_attr( attr, "nbnd",  nbnd )
         CALL iotk_write_attr( attr, "ik",    ik )
         CALL iotk_write_attr( attr, "nk",    nk )
         CALL iotk_write_attr( attr, "kunit", kunit )
         CALL iotk_write_attr( attr, "ispin", ispin )
         CALL iotk_write_attr( attr, "nspin", nspin )
         CALL iotk_write_attr( attr, "igwx",  igwx )
         !
         CALL iotk_write_empty( iuni, "INFO", attr )
         !
      END IF


      ALLOCATE( wtmp( MAX(igwx,1) ) )
      wtmp = 0.0d0

      DO j = 1, nbnd
        IF( npool > 1 ) THEN
          IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
            CALL mergewf( wf(:,j), wtmp, ngwl, igl, me_pool, nproc_pool, root_pool, intra_pool_comm )
          END IF
          IF( ipsour /= ionode_id ) THEN
            CALL mp_get( wtmp, wtmp, mpime, ionode_id, ipsour, j )
          END IF
        ELSE
          CALL mergewf( wf(:,j), wtmp, ngwl, igl, mpime, nproc, ionode_id)
        END IF
        IF ( ionode ) &
            CALL iotk_write_dat( iuni, "evc" // iotk_index( j ), wtmp(1:igwx) )

      END DO

      IF ( ionode ) THEN
         !
         CALL iotk_write_end( iuni, "K-POINT" // iotk_index( ik ) )
         !
         CALL iotk_close_write( iuni )
         !
      END IF

      DEALLOCATE( wtmp )

      RETURN
    END SUBROUTINE write_wfc

!
!
!
!=----------------------------------------------------------------------------=!

    SUBROUTINE read_wfc( iuni, ik, nk, kunit, ispin, nspin, wf, ngw, nbnd, igl, &
                         ngwl, filename )
!
      USE kinds, ONLY: dbl
      USE mp_wave
      USE mp, ONLY: mp_sum, mp_put, mp_bcast, mp_max, mp_get
      USE mp_global, ONLY: mpime, nproc, root, me_pool, my_pool_id, &
        nproc_pool, intra_pool_comm, root_pool, my_image_id
      USE io_global, ONLY: ionode, ionode_id
      USE iotk_module
!
      IMPLICIT NONE
!
      INTEGER, INTENT(IN) :: iuni
      COMPLEX(dbl), INTENT(OUT) :: wf(:,:)
      INTEGER, INTENT(IN) :: ik, nk
      INTEGER, INTENT(INOUT) :: kunit
      INTEGER, INTENT(INOUT) :: ngw, nbnd, ispin, nspin
      INTEGER, INTENT(IN) :: ngwl
      INTEGER, INTENT(IN) :: igl(:)
      CHARACTER(LEN=256), INTENT(IN)    :: filename
      INTEGER                       :: ierr_iotk
      CHARACTER(LEN=iotk_attlenx)   :: attr


      INTEGER :: i, j
      COMPLEX(dbl), ALLOCATABLE :: wtmp(:)
      INTEGER, ALLOCATABLE :: igltot(:)
      INTEGER :: ierr

      INTEGER :: nkl, nkr, nkbl, iks, ike, nkt, ikt, igwx, igwx_
      INTEGER :: ik_, nk_, kunit_
      INTEGER :: npool, ipmask( nproc ), ipdest


      IF( nproc_pool < 1 ) &
         CALL errore( "read_wfc", " nproc_pool less than 1 ", 1 )
     
      IF( kunit < 1 ) &
         CALL errore( "read_wfc", " kunit less than 1 ", 1 )

      ! set working variables for k point index (ikt) and k points number (nkt)
      ikt = ik
      nkt = nk

      !  find out the number of pools
      npool = nproc / nproc_pool

      !  find out number of k points blocks (each block contains kunit k points)
      nkbl = nkt / kunit

      !  k points per pool
      nkl = kunit * ( nkbl / npool )

      !  find out the reminder
      nkr = ( nkt - nkl * npool ) / kunit

      !  Assign the reminder to the first nkr pools
      IF( my_pool_id < nkr ) nkl = nkl + kunit

      !  find out the index of the first k point in this pool
      iks = nkl * my_pool_id + 1
      IF( my_pool_id >= nkr ) iks = iks + nkr * kunit

      !  find out the index of the last k point in this pool
      ike = iks + nkl - 1

      ipmask = 0
      ipdest = ionode_id

      !  find out the index of the processor which collect the data in the pool of ik
      IF( npool > 1 ) THEN
        IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
            IF( me_pool == root_pool ) ipmask( mpime + 1 ) = 1
        END IF
        CALL mp_sum( ipmask )
        DO i = 1, nproc
          IF( ipmask(i) == 1 ) ipdest = ( i - 1 )
        END DO
      END IF

      igwx = 0
      ierr = 0
      IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
        IF( ngwl > SIZE( igl ) ) THEN
          ierr = 1
        ELSE
          igwx = MAXVAL( igl(1:ngwl) )
        END IF
      END IF

      ! get the maximum index within the pool
      !
      CALL mp_max( igwx, intra_pool_comm ) 

      ! now notify all procs if an error has been found 
      !
      CALL mp_max( ierr ) 

      IF( ierr > 0 ) &
        CALL errore(' read_restart_wfc ',' wrong size ngl ', ierr )

      IF( ipdest /= ionode_id ) THEN
        CALL mp_get( igwx, igwx, mpime, ionode_id, ipdest, 1 )
      END IF

      IF ( ionode ) THEN
          !
          CALL iotk_open_read( iuni, FILE = TRIM( filename ), BINARY = .TRUE. )
          !
          CALL iotk_scan_begin( iuni, "K-POINT" // iotk_index( ik ) )
          !
          CALL iotk_scan_empty( iuni, "INFO", attr )
          !
          CALL iotk_scan_attr( attr, "ngw",   ngw )
          CALL iotk_scan_attr( attr, "nbnd",  nbnd )
          CALL iotk_scan_attr( attr, "ik",    ik_ )
          CALL iotk_scan_attr( attr, "nk",    nk_ )
          CALL iotk_scan_attr( attr, "kunit", kunit_ )
          CALL iotk_scan_attr( attr, "ispin", ispin )
          CALL iotk_scan_attr( attr, "nspin", nspin )
          CALL iotk_scan_attr( attr, "igwx",  igwx_ )
          !
      END IF

      CALL mp_bcast( ngw,     ionode_id )
      CALL mp_bcast( nbnd,    ionode_id )
      CALL mp_bcast( ik_ ,    ionode_id )
      CALL mp_bcast( nk_ ,    ionode_id )
      CALL mp_bcast( kunit_ , ionode_id )
      CALL mp_bcast( ispin,   ionode_id )
      CALL mp_bcast( nspin,   ionode_id )
      CALL mp_bcast( igwx_ ,  ionode_id )


      ALLOCATE( wtmp( MAX(igwx_, igwx) ) )

      DO j = 1, nbnd

            IF( j <= SIZE( wf, 2 ) ) THEN

              IF ( ionode ) THEN 
                CALL iotk_scan_dat( iuni, "evc" // iotk_index( j ), wtmp(1:igwx_) )
                IF( igwx > igwx_ ) wtmp( (igwx_ + 1) : igwx ) = 0.0d0
              END IF
 
              IF( npool > 1 ) THEN
                IF( ipdest /= ionode_id ) THEN
                  CALL mp_put( wtmp, wtmp, mpime, ionode_id, ipdest, j )
                END IF
                IF( ( ikt >= iks ) .AND. ( ikt <= ike ) ) THEN
                  CALL splitwf(wf(:,j), wtmp, ngwl, igl, me_pool, nproc_pool, root_pool, intra_pool_comm)
                END IF
              ELSE
                CALL splitwf(wf(:,j), wtmp, ngwl, igl, mpime, nproc, ionode_id)
              END IF

            END IF

      END DO

      IF ( ionode ) THEN
         !
         CALL iotk_scan_end( iuni, "K-POINT" // iotk_index( ik ) )
         !
         CALL iotk_close_read( iuni )
         !
      END IF


      DEALLOCATE( wtmp )

      RETURN
    END SUBROUTINE read_wfc

!=----------------------------------------------------------------------------=!
!

    SUBROUTINE read_cell( ibrav, symm_type, celldm, alat, a1, a2, a3, b1, b2, b3 )
      !
      USE iotk_module
      USE kinds,       ONLY: dbl
      USE io_files,    ONLY: iunpun
      !
      INTEGER,   INTENT(OUT) :: ibrav
      CHARACTER(LEN=*), INTENT(OUT) :: symm_type
      REAL(dbl), INTENT(OUT) :: celldm( 6 ), alat
      REAL(dbl), INTENT(OUT) :: a1( 3 ), a2( 3 ), a3( 3 )
      REAL(dbl), INTENT(OUT) :: b1( 3 ), b2( 3 ), b3( 3 )
      !
      CHARACTER(LEN=256)      :: bravais_lattice
      CHARACTER(iotk_attlenx) :: attr
      !

      call iotk_scan_begin(iunpun,"CELL")
         !
         CALL iotk_scan_dat( iunpun, &
                             "BRAVAIS_LATTICE", bravais_lattice )
         !
         SELECT CASE ( TRIM( bravais_lattice ) )
           CASE( "free" )
              ibrav = 0
           CASE( "cubic P (sc)" )
              ibrav = 1
           CASE( "cubic F (fcc)" )
              ibrav = 2
           CASE( "cubic I (bcc)" )
              ibrav = 3
           CASE( "Hexagonal and Trigonal P" )
              ibrav = 4
           CASE( "Trigonal R" )
              ibrav = 5
           CASE( "Tetragonal P (st)" )
              ibrav = 6
           CASE( "Tetragonal I (bct)" )
              ibrav = 7
           CASE( "Orthorhombic P" )
              ibrav = 8
           CASE( "Orthorhombic base-centered(bco)" )
              ibrav = 9
           CASE( "Orthorhombic face-centered" )
              ibrav = 10
           CASE( "Orthorhombic body-centered" )
              ibrav = 11
           CASE( "Monoclinic P" )
              ibrav = 12
           CASE( "Monoclinic base-centered" )
              ibrav = 13
           CASE( "Triclinic P" )
              ibrav = 14
         END SELECT
         !
         IF ( ibrav == 0 ) &
            CALL iotk_scan_dat( iunpun, "CELL_SYMMETRY", symm_type )
         !
         CALL iotk_scan_dat( iunpun, "LATTICE_PARAMETER", alat )
         call iotk_scan_dat( iunpun, "CELLDM", celldm(1:6))
         !
         CALL iotk_scan_begin( iunpun, "DIRECT_LATTICE_VECTORS" )
           CALL iotk_scan_dat(   iunpun, "a1", a1 )
           CALL iotk_scan_dat(   iunpun, "a2", a2 )
           CALL iotk_scan_dat(   iunpun, "a3", a3 )
         CALL iotk_scan_end(   iunpun, "DIRECT_LATTICE_VECTORS" )
         !
         CALL iotk_scan_begin( iunpun, "RECIPROCAL_LATTICE_VECTORS" )
           CALL iotk_scan_dat(   iunpun, "b1", b1 )
           CALL iotk_scan_dat(   iunpun, "b2", b2 )
           CALL iotk_scan_dat(   iunpun, "b3", b3 )
         CALL iotk_scan_end(   iunpun, "RECIPROCAL_LATTICE_VECTORS" )
         !
      CALL iotk_scan_end( iunpun, "CELL" )

      RETURN
    END SUBROUTINE

!------------------------------------------------------------------------------!
  END MODULE cp_restart
!------------------------------------------------------------------------------!
