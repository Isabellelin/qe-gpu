!
! Copyright (C) 2002 FPMD group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!

!  AB INITIO COSTANT PRESSURE MOLECULAR DYNAMICS

!=----------------------------------------------------------------------------=!
  MODULE runcp_module
!=----------------------------------------------------------------------------=!

        IMPLICIT NONE
        PRIVATE
        SAVE

        PUBLIC :: runcp, runcp_force_pairing
        PUBLIC :: runcp_uspp, runcp_ncpp

!=----------------------------------------------------------------------------=!
        CONTAINS
!=----------------------------------------------------------------------------=!


!  ----------------------------------------------
!  BEGIN manual

    SUBROUTINE runcp( ttprint, tortho, tsde, cm, c0, cp, cdesc, gv, kp, ps, &
      vpot, eigr, fi, ekinc, timerd, timeorto, ht, ei, fnl, vnosee )

!     This subroutine performs a Car-Parrinello or Steepest-Descent step
!     on the electronic variables, computing forces on electrons and,
!     when required, the eigenvalues of the Hamiltonian 
!
!     On output "cp" contains the new plave waves coefficients, while
!     "cm" and "c0" are not changed
!  ----------------------------------------------
!  END manual

! ...   declare modules
      USE kinds
      USE mp_global, ONLY: mpime, nproc
      USE mp, ONLY: mp_sum
      USE electrons_module, ONLY:  pmss, eigs, occ_desc
      USE cp_electronic_mass, ONLY: emass
      USE descriptors_module, ONLY: get_local_dims, owner_of, local_index
      USE wave_functions, ONLY : rande, cp_kinetic_energy, gram
      USE wave_base, ONLY : frice
      USE wave_base, ONLY: hpsi
      USE cp_types, ONLY: recvecs, pseudo, phase_factors
      USE cell_module, ONLY: boxdimensions
      USE time_step, ONLY: delt
      USE forces, ONLY: dforce
      USE orthogonalize, ONLY: ortho
      USE brillouin, ONLY: kpoints
      USE wave_types, ONLY: wave_descriptor
      USE pseudo_projector, ONLY: projector
      USE control_flags, ONLY: tnosee
      USE control_flags, ONLY: tdamp
      USE wave_constrains, ONLY: update_lambda

      IMPLICIT NONE

! ...   declare subroutine arguments

      LOGICAL :: ttprint, tortho, tsde
      COMPLEX(dbl) :: cm(:,:,:,:), c0(:,:,:,:), cp(:,:,:,:)
      TYPE (wave_descriptor), INTENT(IN) :: cdesc
      TYPE (pseudo), INTENT(IN)  ::  ps
      TYPE (phase_factors), INTENT(IN)  ::  eigr
      TYPE (recvecs), INTENT(IN)  ::  gv
      TYPE (kpoints), INTENT(IN)  ::  kp
      REAL(dbl), INTENT(IN)  ::  fi(:,:,:)
      TYPE (boxdimensions), INTENT(IN)  ::  ht
      TYPE (projector) :: fnl(:,:)
      REAL (dbl) ::  vpot(:,:,:,:)
      REAL(dbl) :: ei(:,:,:)
      REAL(dbl) :: timerd, timeorto
      REAL(dbl) :: ekinc(:)
      REAL(dbl), INTENT(IN) :: vnosee

! ...   declare other variables
      REAL(dbl) :: s1, s2, s3, s4
      INTEGER :: ik, nx, nb_l, ierr, nkl, is

      COMPLEX(dbl), ALLOCATABLE :: cgam(:,:,:)
      REAL(dbl),    ALLOCATABLE :: gam(:,:,:)

      REAL(dbl), EXTERNAL :: cclock

! ...   end of declarations
!  ----------------------------------------------

      s1 = cclock()

      CALL get_local_dims( occ_desc, nb_l )
      IF( cdesc%gamma ) THEN
        ALLOCATE( cgam(1,1,1), gam( MAX(1,nb_l), SIZE( c0, 2 ), cdesc%nspin ), STAT=ierr)
      ELSE
        ALLOCATE( cgam(MAX(1,nb_l), SIZE( c0, 2 ), cdesc%nspin ), gam(1,1,1), STAT=ierr)
      END IF
      IF( ierr /= 0 ) CALL errore(' runcp ', ' allocating gam, prod ', ierr)

      ekinc    = 0.0d0
      timerd   = 0.0d0
      timeorto = 0.0d0

      !  Compute electronic forces and move electrons

      CALL runcp_ncpp( cm, c0, cp, cdesc, gv, kp, ps, vpot, eigr, fi, fnl, vnosee, &
           gam, cgam, lambda = ttprint )

      !  Compute eigenstate
      !
      IF( ttprint ) THEN
        DO is = 1, cdesc%nspin
          nx = cdesc%nbt( is )
          nkl  = cdesc%nkl
          DO ik = 1, nkl
              CALL eigs( nx, gam(:,:,is), cgam(:,:,is), tortho, fi(:,ik,is), ei(:,ik,is), cdesc%gamma )
          END DO
        END DO
      END IF

      s2 = cclock()
      timerd = s2 - s1

      !  Orthogonalize the new wave functions "cp"

      IF( tortho ) THEN
        CALL ortho(c0, cp, cdesc, pmss, emass)
      ELSE
        CALL gram(cp, cdesc)
      END IF

      s3 = cclock()
      timeorto = s3 - s2

      !  Compute fictitious kinetic energy of the electrons at time t

      DO is = 1, cdesc%nspin
        ekinc(is) = cp_kinetic_energy( is, cp(:,:,:,is), cm(:,:,:,is), cdesc, kp, &
          gv%kg_mask_l, pmss, delt)
      END DO

      DEALLOCATE( cgam, gam, STAT=ierr)
      IF( ierr /= 0 ) CALL errore(' runcp ', ' deallocating 1 ', ierr)


      RETURN
    END SUBROUTINE runcp


!=----------------------------------------------------------------------------------=!


!  ----------------------------------------------
!  BEGIN manual

    SUBROUTINE runcp_ncpp( cm, c0, cp, cdesc, gv, kp, ps, &
      vpot, eigr, fi, fnl, vnosee, gam, cgam, lambda, fromscra, diis, restart )

!     This subroutine performs a Car-Parrinello or Steepest-Descent step
!     on the electronic variables, computing forces on electrons and,
!     when required, the eigenvalues of the Hamiltonian 
!
!     On output "cp" contains the new plave waves coefficients, while
!     "cm" and "c0" are not changed
!  ----------------------------------------------
!  END manual

! ...   declare modules
      USE kinds
      USE mp_global, ONLY: mpime, nproc
      USE mp, ONLY: mp_sum
      USE electrons_module, ONLY:  pmss, occ_desc
      USE cp_electronic_mass, ONLY: emass
      USE wave_base, ONLY: frice, wave_steepest, wave_verlet
      USE cp_types, ONLY: recvecs, pseudo, phase_factors
      USE time_step, ONLY: delt
      USE forces, ONLY: dforce
      USE brillouin, ONLY: kpoints
      USE wave_types, ONLY: wave_descriptor
      USE wave_constrains, ONLY: update_lambda
      USE control_flags, ONLY: tnosee, tdamp, tsde
      USE pseudo_projector, ONLY: projector

      IMPLICIT NONE

! ...   declare subroutine arguments

      COMPLEX(dbl) :: cm(:,:,:,:), c0(:,:,:,:), cp(:,:,:,:)
      COMPLEX(dbl) :: cgam(:,:,:)
      REAL(dbl)    :: gam(:,:,:)
      TYPE (wave_descriptor), INTENT(IN) :: cdesc
      TYPE (pseudo), INTENT(IN)  ::  ps
      TYPE (phase_factors), INTENT(IN)  ::  eigr
      TYPE (recvecs), INTENT(IN)  ::  gv
      TYPE (kpoints), INTENT(IN)  ::  kp
      REAL(dbl), INTENT(IN)  ::  fi(:,:,:)
      TYPE (projector) :: fnl(:,:)
      REAL (dbl) ::  vpot(:,:,:,:)
      REAL(dbl), INTENT(IN) :: vnosee
      LOGICAL, OPTIONAL, INTENT(IN) :: lambda, fromscra, diis, restart

! ...   declare other variables
      REAL(dbl) ::  svar1, svar2, tmpfac, annee
      INTEGER :: i, ik, ig, nx, ngw, nb, ierr, nkl, is
      INTEGER :: iflag

      COMPLEX(dbl), ALLOCATABLE :: c2(:), c3(:)
      REAL(dbl),    ALLOCATABLE :: svar3(:)
      LOGICAL :: tlam, ttsde


! ...   end of declarations
!  ----------------------------------------------

      IF( PRESENT( lambda ) ) THEN
        tlam = lambda
      ELSE
        tlam = .FALSE.
      END IF

      iflag = 0
      IF( PRESENT( fromscra ) ) THEN
        IF( fromscra ) iflag = 1
      END IF
      IF( PRESENT( restart ) ) THEN
        IF( restart ) iflag = 2
      END IF


      ! WRITE(6,*) 'DEBUG: ', tlam

      nkl  = cdesc%nkl
      IF( nkl /= SIZE( fi, 2 ) ) &
        CALL errore(' runcp ',' inconsistent number of kpoints ', 1)

      ngw  = cdesc%ngwl

      ALLOCATE( c2(ngw), c3(ngw), svar3(ngw), STAT = ierr )
      IF( ierr /= 0 ) CALL errore(' runcp_ncpp ', ' allocating c2, c3, svar3 ', ierr)

      ! ...   determines friction dynamically according to the Nose' dynamics
      !

      IF( tnosee ) THEN
        annee   = vnosee * delt * 0.5d0
      ELSE IF ( tdamp ) THEN
        annee   = frice
      ELSE
        annee   = 0.0d0
      END IF
      tmpfac  = 1.d0 / (1.d0 + annee)

      IF( iflag == 0 ) THEN
        ttsde   = tsde
        svar1   = 2.d0 * tmpfac
        svar2   = 1.d0 - svar1
        svar3( 1:ngw ) = delt * delt / pmss( 1:ngw ) * tmpfac
      ELSE IF ( iflag == 1 ) THEN
        ttsde   = .TRUE.
        svar1   = 1.d0
        svar2   = 2.d0
        svar3( 1:ngw ) = delt * delt / pmss( 1:ngw )
      ELSE IF ( iflag == 2 ) THEN
        ttsde = .FALSE.
        svar1 = 1.d0
        svar2 = 0.d0
        svar3 = delt * delt / pmss( 1:ngw ) * 0.5d0
      END IF

      DO is = 1, cdesc%nspin

        nx   = cdesc%nbt( is )
        IF( nx > SIZE( fi, 1 ) ) &
          CALL errore(' runcp ',' inconsistent occupation numbers ', 1)

        KAPPA: DO ik = 1, nkl

          nb = nx - MOD(nx, 2)

          DO i = 1, nb, 2

            IF ( cdesc%gamma ) THEN
              CALL dforce( ik, i, c0(:,:,:,is), cdesc, fi(:,:,is), c2, c3, gv, vpot(:,:,:,is), &
                fnl(ik, is)%r(:,:,:), eigr, ps )
            ELSE
              CALL dforce( ik, i, c0(:,:,:,is), cdesc, fi(:,:,is), c2, gv, vpot(:,:,:,is), &
                fnl(ik, is)%c, eigr, ps )
              CALL dforce( ik, i+1, c0(:,:,:,is), cdesc, fi(:,:,is), c3, gv, vpot(:,:,:,is), &
                fnl(ik, is)%c, eigr, ps )
            END IF

            IF( tlam ) THEN
              IF ( cdesc%gamma ) THEN
                CALL update_lambda( i, gam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c2 )
                CALL update_lambda( i+1, gam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c3 )
              ELSE
                CALL update_lambda( i, cgam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c2 )
                CALL update_lambda( i+1, cgam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c3 )
              END IF
            END IF

            IF( iflag == 2 ) THEN
              c0(:,i,ik,is) = cp(:,i,ik,is)
              c0(:,i+1,ik,is) = cp(:,i+1,ik,is)
            END IF

            IF ( ttsde ) THEN
              CALL wave_steepest( cp(:,i,ik,is), c0(:,i,ik,is), svar3, c2 )
              CALL wave_steepest( cp(:,i+1,ik,is), c0(:,i+1,ik,is), svar3, c3 )
            ELSE
              cp(:,i,ik,is) = cm(:,i,ik,is)
              cp(:,i+1,ik,is) = cm(:,i+1,ik,is)
              CALL wave_verlet( cp(:,i,ik,is), c0(:,i,ik,is), svar1, svar2, svar3, c2 )
              CALL wave_verlet( cp(:,i+1,ik,is), c0(:,i+1,ik,is), svar1, svar2, svar3, c3 )
            END IF
            IF( .NOT. cdesc%gamma ) THEN
              cp(:,i,ik,is)  = cp(:,i,ik,is) * gv%kg_mask_l(:,ik)
              cp(:,i+1,ik,is)  = cp(:,i+1,ik,is) * gv%kg_mask_l(:,ik)
            ELSE
              IF( cdesc%gzero ) cp(1,i,ik,is) = REAL( cp(1,i,ik,is), dbl )
              IF( cdesc%gzero ) cp(1,i+1,ik,is) = REAL( cp(1,i+1,ik,is), dbl )
            END IF

          END DO

          IF( MOD(nx,2) /= 0) THEN
            nb = nx
            IF ( cdesc%gamma ) THEN
              CALL dforce( ik, nb, c0(:,:,:,is), cdesc, fi(:,:,is), c2, gv, vpot(:,:,:,is), &
                 fnl(ik,is)%r(:,:,:), eigr, ps )
            ELSE
              CALL dforce( ik, nb, c0(:,:,:,is), cdesc, fi(:,:,is), c2, gv, vpot(:,:,:,is), &
                 fnl(ik,is)%c, eigr, ps )
            END IF
            IF( tlam ) THEN
              IF ( cdesc%gamma ) THEN
                CALL update_lambda( nb, gam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c2 )
              ELSE
                CALL update_lambda( nb, cgam( :, :,is), occ_desc, c0(:,:,ik,is), cdesc, c2 )
              END IF
            END IF

            IF( iflag == 2 ) THEN
              c0(:,nb,ik,is) = cp(:,nb,ik,is)
            END IF

            IF ( ttsde ) THEN
              CALL wave_steepest( cp(:,nb,ik,is), c0(:,nb,ik,is), svar3, c2 )
            ELSE
              cp(:,nb,ik,is) = cm(:,nb,ik,is)
              CALL wave_verlet( cp(:,nb,ik,is), c0(:,nb,ik,is), svar1, svar2, svar3, c2 )
            END IF
            IF( .NOT. cdesc%gamma ) THEN
              cp(:,nb,ik,is)  = cp(:,nb,ik,is) * gv%kg_mask_l(:,ik)
            ELSE
              IF( cdesc%gzero ) cp(1,nb,ik,is) = REAL( cp(1,nb,ik,is), dbl )
            END IF

          END IF

        END DO KAPPA

      END DO

      DEALLOCATE(svar3, c2, c3, STAT=ierr)
      IF( ierr /= 0 ) CALL errore(' runcp_ncpp ', ' deallocating 1 ', ierr)

      RETURN
    END SUBROUTINE runcp_ncpp


!=----------------------------------------------------------------------------------=!


!cdesc is the desciptor for the wf
!gv g vector
!eigr==e^ig*r f is the occupation number
!fnl if the factor non local

    SUBROUTINE runcp_force_pairing(ttprint, tortho, tsde, cm, c0, cp, cdesc, gv, kp, ps, &
        vpot, eigr, fi, ekinc, timerd, timeorto, ht, ei, fnl, vnosee)

!  same as runcp, except that electrons are paired forcedly
!  i.e. this handles a state dependant Hamiltonian for the paired and unpaired electrons
!  unpaired is assumed to exist, to be unique, and located in highest index band
!  ----------------------------------------------
!  END manual

! ...   declare modules
      USE kinds
      USE mp_global, ONLY: mpime, nproc, group
      USE mp, ONLY: mp_sum
      USE electrons_module, ONLY: pmss, eigs, occ_desc, nupdwn, nspin
      USE cp_electronic_mass, ONLY: emass
      USE descriptors_module, ONLY: get_local_dims, owner_of, local_index
      USE wave_functions, ONLY : rande, cp_kinetic_energy, gram
      USE wave_base, ONLY: frice, wave_steepest, wave_verlet
      USE wave_base, ONLY: hpsi
      USE cp_types, ONLY: recvecs, pseudo, phase_factors
      USE cell_module, ONLY: boxdimensions
      USE time_step, ONLY: delt
      USE forces, ONLY: dforce
      USE orthogonalize, ONLY: ortho
      USE brillouin, ONLY: kpoints
      USE wave_types, ONLY: wave_descriptor
      USE pseudo_projector, ONLY: projector
      USE control_flags, ONLY: tnosee
      USE control_flags, ONLY: tdamp
      USE constants, ONLY: au
      USE io_global, ONLY: ionode
      USE wave_constrains, ONLY: update_lambda

        IMPLICIT NONE

! ...   declare subroutine arguments

      LOGICAL :: ttprint, tortho, tsde
      COMPLEX(dbl) :: cm(:,:,:,:), c0(:,:,:,:), cp(:,:,:,:)
      TYPE (wave_descriptor), INTENT(IN) :: cdesc
      TYPE (pseudo), INTENT(IN)  ::  ps
      TYPE (phase_factors), INTENT(IN)  ::  eigr
      TYPE (recvecs), INTENT(IN)  ::  gv
      TYPE (kpoints), INTENT(IN)  ::  kp
      REAL(dbl), INTENT(INOUT) ::  fi(:,:,:)
      TYPE (boxdimensions), INTENT(IN)  ::  ht
      TYPE (projector) :: fnl(:,:)
      REAL (dbl) ::  vpot(:,:,:,:)
      REAL(dbl) :: ei(:,:,:)
      REAL(dbl) :: timerd, timeorto
      REAL(dbl) :: ekinc(:)
      REAL(dbl), INTENT(IN) :: vnosee

! ...   declare other variables
      REAL(dbl) :: s3, s4
      REAL(dbl) ::  svar1, svar2, tmpfac, annee
      INTEGER :: i, ik,ig, nx, ngw, nb, j, nb_g, nb_l, ierr, nkl, ibl
      INTEGER :: ispin_wfc
      REAL(dbl), ALLOCATABLE :: occup(:,:), occdown(:,:), occsum(:)
      REAL(dbl) :: intermed, intermed2
      COMPLEX(dbl) ::  intermed3, intermed4


      COMPLEX(dbl), ALLOCATABLE :: c2(:)
      COMPLEX(dbl), ALLOCATABLE :: c3(:)
      COMPLEX(dbl), ALLOCATABLE :: c4(:)
      COMPLEX(dbl), ALLOCATABLE :: c5(:)
      COMPLEX(dbl), ALLOCATABLE :: cgam(:,:)
      COMPLEX(dbl), ALLOCATABLE :: cprod(:)
      REAL(dbl),    ALLOCATABLE :: svar3(:)
      REAL(dbl),    ALLOCATABLE :: gam(:,:)
      REAL(dbl),    ALLOCATABLE :: prod(:)
      REAL(dbl),    ALLOCATABLE :: ei_t(:,:,:)

      REAL(dbl), EXTERNAL :: cclock

! ...   end of declarations
!  ----------------------------------------------

      IF( nspin == 1 ) &
        CALL errore(' runcp_forced_pairing ',' inconsistent nspin ', 1)

      nkl  = cdesc%nkl
      IF( nkl /= SIZE( fi, 2 ) ) &
        CALL errore(' runcp_forced_pairing ',' inconsistent number of kpoints ', 1)

      ngw  = cdesc%ngwl

      ALLOCATE(c2(ngw), c3(ngw), c4(ngw), c5(ngw), svar3(ngw), STAT=ierr)
      IF( ierr /= 0 ) CALL errore(' runcp_forced_pairing ', ' allocating c2, c3, svar3 ', ierr)


! ...   determines friction dynamically according to the Nose' dynamics
      IF( tnosee ) THEN
        annee   = vnosee * delt * 0.5d0
      ELSE IF ( tdamp ) THEN
        annee   = frice
      ELSE
        annee   = 0.0d0
      END IF

      tmpfac  = 1.d0 / (1.d0 + annee)
      svar1   = 2.d0 * tmpfac
      svar2   = 1.d0 - svar1
      svar3(1:ngw) = delt * delt / pmss(1:ngw) * tmpfac

      ekinc    = 0.0d0
      timerd   = 0.0d0
      timeorto = 0.0d0

      nx   = cdesc%nbt( 1 )
      IF( nx /= SIZE( fi, 1 ) ) &
        CALL errore(' runcp_forced_pairing ',' inconsistent occupation numbers ', 1)

      IF( nupdwn(1) /= (nupdwn(2) + 1) ) &
        CALL errore(' runcp_forced_pairing ',' inconsistent spin numbers ', 1)

      nb_g = cdesc%nbt( 1 )
      CALL get_local_dims( occ_desc, nb_l )

      IF( cdesc%gamma ) THEN
        ALLOCATE(cgam(1,1), cprod(1), gam(MAX(1,nb_l),nb_g), prod(nb_g), STAT=ierr)
      ELSE
        ALLOCATE(cgam(MAX(1,nb_l),nb_g), cprod(nb_g), gam(1,1), prod(1), STAT=ierr)
      END IF
      IF( ierr /= 0 ) CALL errore(' runcp_forced_pairing ', ' allocating gam, prod ', ierr)

      ALLOCATE( occup(nx,nkl), occdown(nx,nkl), STAT=ierr )
      if ( ierr/=0 ) CALL errore(' runcp_forced_pairing ', 'allocating occup, occdown', ierr)

      ALLOCATE (ei_t(nx,nkl,2), STAT=ierr)
      IF( ierr /= 0 ) CALL errore(' runcp_forced_pairing ', 'allocating iei_t', ierr)

      occup   = 0.D0
      occdown = 0.D0
      occup(  1:nupdwn(1), 1:nkl )  = fi( 1:nupdwn(1), 1:nkl, 1 )
      occdown( 1:nupdwn(2), 1:nkl ) = fi( 1:nupdwn(2), 1:nkl, 2 ) 

      !  ciclo sui punti K

      KAPPA: DO ik = 1, nkl

        s4 = cclock()

        !  inizia a trattare lo stato unpaired
        !  per lo spin_up unpaired

        if ( nupdwn(1) == (nupdwn(2) + 1) ) then
           !
           intermed = sum ( c0( :, nupdwn(1), ik, 1 ) * conjg( c0( :, nupdwn(1), ik, 1 ) ) )
           !  prodotto delle wf relative all'unpaired el
           !  lavoro sugli n processori e' per quetso che sommo ... 
           !  vengono messi nella variabile temporanea ei_t(:,:,2)
           !  ei_t(:,:,1) viene utilizzato in seguito solo per il controllo/conto su <psi|H H|psi><psiunp|psiunp>
           !  questo e' dovuto al fatto che non posso calcolare gli autovalori con eigs a causa della diversa
           !  occupazione: lo stato unp dovrebbe gia' essere di suo uno stato di KS
           !  cmq NON LO POSSO RUOTARE per come e' scritta la rho = sum_{i_1,N} |psi_i|**2 + |psi_unp|**2
           !
           CALL mp_sum( intermed, group)
           ei_t(:,ik,2) = intermed  ! <Phiunpaired|Phiunpaired>
           !  l'autoval dello spin up spaiato la mette in ei; memoria temporanea??? 
           !
        endif

        !  da qui e' per la trattazione degli el. paired, come in LSD dato che utilizzo
        !  vpot (:,:,:,1) e vpot(:,:,:,2) -nota e' def in spazio R(x,y,z)
        !  mentre dire c0(:,:,:1) o c0(:,:,:,2) e' la stessa cosa
        !  accoppiamento che segue e' solo per motivi tecnici
        !  se il numero di bande e' pari o dispari
        !  indip dal conto sic o dal particolare problema fisico
        !  per semplicita' ... di conto considero bande pari
        !  e poi l'ultima come "dissaccoppiata"
        !  ripeto questo e' un accoppiamento di bande e non di elettroni
        !  non faccio alcuna distinzione finora fra gli el

        nb = nx - MOD(nx, 2)

        DO i = 1, nb, 2

          IF (  cdesc%gamma  ) THEN

            !  dforce calcola la forza c2 e c3 sulle bande i e i+1 (sono reali => ne fa due alla volta)
            !  per il vpot (da potential ed e' il potetnziale di KS) in spin up e in down
            !
            CALL dforce( ik, i, c0(:,:,:,1), cdesc, fi(:,:,1), c2, c3, gv, vpot(:,:,:,1), &
                fnl(ik, 1)%r(:,:,:), eigr, ps )
            CALL dforce( ik, i, c0(:,:,:,1), cdesc, fi(:,:,2), c4, c5, gv, vpot(:,:,:,2), &
                fnl(ik, 2)%r(:,:,:), eigr, ps )
            !
            !  accoppia c2 e c3 da vpot (spin 1) stato i e i+1
            !           c4   c5               2
            !  per lo stesso stato con spin diverso
            !  qui calcolo la forza H|psi> ma e' gia' dato il contributo sia up che dwn
            !  e quindi qui ho occupazione "fi==2" per gli stati paired; mentre rimane "fi==1" per l'unpaired

            c2 = occup(i  , ik)*c2 + occdown(i  , ik)*c4
            c3 = occup(i+1, ik)*c3 + occdown(i+1, ik)*c5
            !
            !  se l'unpaired e' nell'ultima banda "pari"
            !  allora e' lo stato i+1 e andra' in c3 che per def si trovera' ad avere occdwn=0.d0
            !  combina in c2 la forza degli spin up/down relativa alla banda i
            !  conbina in c3 la forza "  "    "   "   "   "   "    "     "   i+1
            !
          ELSE
            !
            ! se non sono in gamma non posso fare due bande in contemporanea...
            ! raddoppia (questa pesa un 30/40% sul conto)
            ! qui sono in C => ogni FFT serve per una wf complessa che ha bisogno di due componenti

            CALL dforce( ik, i, c0(:,:,:,1), cdesc, fi(:,:,1), c2, gv, vpot(:,:,:,1), &
                fnl(ik, 1)%c, eigr, ps )
            CALL dforce( ik, i, c0(:,:,:,1), cdesc, fi(:,:,2), c4, gv, vpot(:,:,:,2), &
                fnl(ik, 2)%c, eigr, ps )

            c2 = occup(i, ik)*c2 + occdown(i, ik)*c4

            CALL dforce( ik, i+1, c0(:,:,:,1), cdesc, fi(:,:,1), c3, gv, vpot(:,:,:,1), &
                fnl(ik, 1)%c, eigr, ps )
            CALL dforce( ik, i+1, c0(:,:,:,1), cdesc, fi(:,:,2), c5, gv, vpot(:,:,:,2), &
                fnl(ik, 2)%c, eigr, ps )

            c3 = occup(i+1, ik)*c3 + occdown(i+1, ik)*c5
            !
          END IF

          IF( ttprint ) then

            IF ( cdesc%gamma ) THEN
                !
                !  c2 e' l'array di comb. lin. dH/dpsi stato i   con spin_up e dwn
                !  c3                                        i+1
                !  anche solita divisione sul gamma == matrice lambda dei moltiplicatori di Lagrange
                !  e faccio il prodotto <psi|dH/dpsi> == <psi|H|psi>
                !
                CALL update_lambda( i, gam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c2 )
                CALL update_lambda( i+1, gam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c3 )

            ELSE

                CALL update_lambda( i, cgam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c2 )
                CALL update_lambda( i+1, cgam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c3 )

            END IF

            if ( nupdwn(1) > nupdwn(2) ) then
                intermed  = sum ( c2* conjg(c2) )
                intermed2 = sum ( c3* conjg(c3) )
                intermed3 = sum ( c2* conjg( c0(:,nupdwn(1),ik,1) ) )
                intermed4 = sum ( c3* conjg( c0(:,nupdwn(1),ik,1) ) )
                CALL mp_sum ( intermed,  group )
                CALL mp_sum ( intermed2, group )
                CALL mp_sum ( intermed3, group )
                CALL mp_sum ( intermed4, group )
                ei_t(i  ,ik,1) = intermed  * ei_t(i  ,ik,2) ! <Phi|H H|Phi>*<Phiunpaired|Phiunpaired>
                ei_t(i+1,ik,1) = intermed2 * ei_t(i+1,ik,2)
                ei_t(i  ,ik,2) = abs (intermed3)
                ei_t(i+1,ik,2) = abs (intermed4)
            endif

          END IF ! ttprint

          IF ( tsde ) THEN
             CALL wave_steepest( cp(:,i,ik,1), c0(:,i,ik,1), svar3, c2 )
             CALL wave_steepest( cp(:,i+1,ik,1), c0(:,i+1,ik,1), svar3, c3 )
          ELSE
            cp(:,i,ik,1) = cm(:,i,ik,1)
            cp(:,i+1,ik,1) = cm(:,i+1,ik,1)
            CALL wave_verlet( cp(:,i,ik,1), c0(:,i,ik,1), svar1, svar2, svar3, c2 )
            CALL wave_verlet( cp(:,i+1,ik,1), c0(:,i+1,ik,1), svar1, svar2, svar3, c3 )
          END IF
          IF( .NOT. cdesc%gamma ) THEN
            cp(:,i,ik,1)  = cp(:,i,ik,1) * gv%kg_mask_l(:,ik)
            cp(:,i+1,ik,1)  = cp(:,i+1,ik,1) * gv%kg_mask_l(:,ik)
          ELSE
            IF( cdesc%gzero ) cp(1,i,ik,1) = REAL( cp(1,i,ik,1), dbl )
            IF( cdesc%gzero ) cp(1,i+1,ik,1) = REAL( cp(1,i+1,ik,1), dbl )
          END IF


        END DO ! bande


        IF( MOD(nx,2) /= 0) THEN

          nb = nx
          !
          !  devo trattare solo l'tulima banda che conterra' di sicuro l'el unpaired
          !  in c2 ho quindi la forza relativa all'el unpaired
          !  per questo conservo in ei_t(:,:,2) il suo autovalore
          !
          IF ( cdesc%gamma ) THEN
                CALL dforce( ik, nb, c0(:,:,:,1), cdesc, fi(:,:,1), c2, gv, vpot(:,:,:,1), &
                   fnl(ik,1)%r(:,:,:), eigr, ps )
                CALL dforce( ik, nb, c0(:,:,:,1), cdesc, fi(:,:,2), c3, gv, vpot(:,:,:,2), &
                   fnl(ik,2)%r(:,:,:), eigr, ps )
                c2 = occup(nb, ik)*c2 + occdown(nb, ik)*c3
          ELSE
                CALL dforce( ik, nb, c0(:,:,:,1), cdesc, fi(:,:,1), c2, gv, vpot(:,:,:,1), &
                   fnl(ik,1)%c, eigr, ps )
                CALL dforce( ik, nb, c0(:,:,:,1), cdesc, fi(:,:,2), c3, gv, vpot(:,:,:,2), &
                   fnl(ik,2)%c, eigr, ps )
                c2 = occup(nb, ik)*c2 + occdown(nb, ik)*c3
          END IF

          IF( ttprint .and. ( nupdwn(1) > nupdwn(2) ) ) THEN
            IF ( cdesc%gamma ) THEN
              CALL update_lambda( nb, gam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c2 )
            ELSE
              CALL update_lambda( nb, cgam( :, :), occ_desc, c0(:,:,ik,1), cdesc, c2 )
            END IF
            if ( nupdwn(1) > nupdwn(2) ) then
              intermed  = sum ( c2 * conjg(c2) )
              intermed3 = sum ( c2 * conjg( c0(:, nupdwn(1), ik, 1) ) )
              CALL mp_sum ( intermed, group )
              CALL mp_sum ( intermed3, group )
              ei_t(nb,ik,1) = intermed * ei_t(nb,ik,2) ! <Phi|H H|Phi>*<Phiunpaired|Phiunpaired>
              ei_t(nb,ik,2) = abs (intermed3)
            endif
          END IF

          IF ( tsde ) THEN
             CALL wave_steepest( cp(:,nb,ik,1), c0(:,nb,ik,1), svar3, c2 )
          ELSE
           cp(:,nb,ik,1) = cm(:,nb,ik,1)
            CALL wave_verlet( cp(:,nb,ik,1), c0(:,nb,ik,1), svar1, svar2, svar3, c2 )
          END IF
          IF( .NOT. cdesc%gamma ) THEN
            cp(:,nb,ik,1)  = cp(:,nb,ik,1) * gv%kg_mask_l(:,ik)
          ELSE
            IF( cdesc%gzero ) cp(1,nb,ik,1) = REAL( cp(1,nb,ik,1), dbl )
          END IF


        END IF


        IF( ttprint ) THEN

            IF ( nupdwn(1) == nupdwn(2) ) THEN

              CALL eigs( nupdwn(1), gam, cgam, tortho, fi(:,ik,1), ei(:,ik,1), cdesc%gamma )

            ELSE IF( nupdwn(1) == ( nupdwn(2) + 1 ) ) THEN

              IF( ionode .AND. ( nupdwn(2) > 0 ) ) THEN
                WRITE(6,1006) 
                WRITE(6,1003) ik, 1
                WRITE(6,1004) 
                WRITE(6,1007) ( ei_t( i, ik, 2 ) * au, i = 1, nupdwn(2) )
              END IF

              DO i = 1, nupdwn(2)
                ei_t(i, ik, 1) = ei_t(i, ik, 2) * ei_t(i,ik,2) / ei_t(i, ik, 1)
              END DO

              IF( ionode ) THEN
                WRITE(6,1002) ik, 1
                WRITE(6,1004) 
                WRITE(6,1007) ( ei_t( i, ik, 1), i = 1, nupdwn(1) )
                WRITE(6,1005)  ei_t( nb, ik, 2)
              END IF

1002          FORMAT(/,3X,'presence in unpaired space (%), kp = ',I3, ' , spin = ',I2,/)
1003          FORMAT(/,3X,'energie cross-terms <Phunpaired| H|Phipaired>, kp = ',I3, ' , spin = ',I2,/)
1004          FORMAT(/,3X,'componente ei_t(i,,1)==<Phi|H H|Phi>*<Phiunpaired|Phiunpaired> su spin up')
1005          FORMAT(/,3X,'eigenvalue  (ei_t) unpaired electron: ei_unp = ',F8.4,/)
1006          FORMAT(/,3X,'eigenvalues (ei_t) for states UP == DWN')
1007          FORMAT(/,3X,10F8.4)

              ALLOCATE( occsum( SIZE( fi, 1 ) ) )
              occsum(:) = occup(:,ik) + occdown(:,ik)

              !  CALCOLO GLI AUTOVAL di KS per le wf paired
              !  impongo il vincolo del force_pairing che spin up e dwn siano uguali
              !  infine metto gli autovalori in ei

              if( cdesc%gamma ) then
                CALL eigs(nupdwn(2), gam, cgam, tortho, occsum, ei(:,ik,1), cdesc%gamma)
              else
                CALL eigs(nupdwn(2), gam, cgam, tortho, occsum, ei(:,ik,1), cdesc%gamma)
              endif
              DEALLOCATE( occsum )
              DO i = 1, nupdwn(2)
                ei( i, ik, 2 ) = ei( i , ik, 1)
              END DO
              ei(nupdwn(1), ik, 1)  = ei_t(nupdwn(1), ik, 2)
              ei(nupdwn(1), ik, 2)  = 0.D0
              ei_t(nupdwn(1), ik, 2)  = 0.D0

            ELSE

              CALL errore( ' runcp_force_pairing ', ' wrong nupdwn ', 1 )

            END IF

        ENDIF

      END DO KAPPA

      s3 = cclock()
      timerd = timerd + s3 - s4

      IF( tortho ) THEN
        CALL ortho( 1, c0(:,:,:,1), cp(:,:,:,1), cdesc, pmss, emass)
      ELSE
        CALL gram(1, cp(:,:,:,1), cdesc)
      END IF


      s4 = cclock()
      timeorto = timeorto + s4 - s3

      !  Compute fictitious kinetic energy of the electrons at time t

      ekinc(1) = cp_kinetic_energy( 1, cp(:,:,:,1), cm(:,:,:,1), cdesc, kp, &
        gv%kg_mask_l, pmss, delt)
      ekinc(2) = cp_kinetic_energy( 2, cp(:,:,:,1), cm(:,:,:,1), cdesc, kp, &
        gv%kg_mask_l, pmss, delt)


      DEALLOCATE( ei_t, svar3, c2, c3, c4, c5, cgam, gam, cprod, prod, occup, occdown, STAT=ierr)
      IF( ierr /= 0 ) CALL errore(' runcp_force_pairing ', ' deallocating ', ierr)

      RETURN
    END SUBROUTINE runcp_force_pairing


!=----------------------------------------------------------------------------=!


   SUBROUTINE runcp_uspp( nfi, fccc, ccc, ema0bg, dt2bye, rhos, bec, c0, cm, &
              fromscra, restart )
     !
     use wave_base, only: wave_steepest, wave_verlet
     use wave_base, only: frice
     use control_flags, only: tnosee, tbuff, lwf, tsde
     !use uspp, only : nhsa=> nkb, betae => vkb, rhovan => becsum, deeq
     use uspp, only : deeq, betae => vkb
     use reciprocal_vectors, only : gstart
     use electrons_base, only : n=>nbnd
     use wannier_subroutines, only: ef_potential
     use efield_module, only: dforce_efield, tefield

     use gvecw, only: ngw
     !
     IMPLICIT NONE
     integer, intent(in) :: nfi
     real(kind=8) :: fccc, ccc
     real(kind=8) :: ema0bg(:), dt2bye
     real(kind=8) :: rhos(:,:)
     real(kind=8) :: bec(:,:)
     complex(kind=8) :: c0(:,:), cm(:,:)
     logical, optional, intent(in) :: fromscra
     logical, optional, intent(in) :: restart
     !
     real(kind=8) ::  verl1, verl2, verl3
     real(kind=8), allocatable:: emadt2(:)
     real(kind=8), allocatable:: emaver(:)
     complex(kind=8), allocatable:: c2(:), c3(:)
     integer :: i
     integer :: iflag
     logical :: ttsde

     iflag = 0
     IF( PRESENT( fromscra ) ) THEN
       IF( fromscra ) iflag = 1
     END IF
     IF( PRESENT( restart ) ) THEN
       IF( restart ) iflag = 2
     END IF

     !
     !==== set friction ====
     !
     IF( iflag == 0 ) THEN
       if( tnosee ) then
         verl1 = 2.0d0 * fccc
         verl2 = 1.0d0 - verl1
         verl3 = 1.0d0 * fccc
       else
         verl1=2./(1.+frice)
         verl2=1.-verl1
         verl3=1./(1.+frice)
       end if
     ELSE IF( iflag == 1 .OR. iflag == 2 ) THEN
       verl1 = 1.0d0
       verl2 = 0.0d0
     END IF

     allocate(c2(ngw))
     allocate(c3(ngw))
     ALLOCATE( emadt2( ngw ) )
     ALLOCATE( emaver( ngw ) )


     IF( iflag == 0 ) THEN
       emadt2 = dt2bye * ema0bg
       emaver = emadt2 * verl3
       ttsde = tsde
     ELSE IF( iflag == 1 ) THEN
       ccc = 0.5d0 * dt2bye
       if(tsde) ccc = dt2bye
       emadt2 = ccc * ema0bg
       emaver = emadt2
       ttsde = .TRUE.
     ELSE IF( iflag == 2 ) THEN
       emadt2 = dt2bye * ema0bg
       emaver = emadt2 * 0.5d0
       ttsde = .FALSE.
     END IF

      if( lwf ) then
        call ef_potential( nfi, rhos, bec, deeq, betae, c0, cm, emadt2, emaver, verl1, verl2, c2, c3 )
      else
        do i=1,n,2
           call dforce(bec,betae,i,c0(1,i),c0(1,i+1),c2,c3,rhos)
           if( tefield ) then
             CALL dforce_efield ( bec, i, c0(:,i), c2, c3, rhos)
           end if
           IF( iflag == 2 ) THEN
             cm(:,i)   = c0(:,i)
             cm(:,i+1) = c0(:,i+1)
           END IF
           if( ttsde ) then
              CALL wave_steepest( cm(:, i  ), c0(:, i  ), emadt2, c2 )
              CALL wave_steepest( cm(:, i+1), c0(:, i+1), emadt2, c3 )
           else
              CALL wave_verlet( cm(:, i  ), c0(:, i  ), verl1, verl2, emaver, c2 )
              CALL wave_verlet( cm(:, i+1), c0(:, i+1), verl1, verl2, emaver, c3 )
           endif
           if ( gstart == 2 ) then
              cm(1,  i)=cmplx(real(cm(1,  i)),0.0)
              cm(1,i+1)=cmplx(real(cm(1,i+1)),0.0)
           end if
        end do
      end if

     IF( iflag == 0 ) THEN
       ccc = fccc * dt2bye
     END IF

     DEALLOCATE( emadt2 )
     DEALLOCATE( emaver )
     deallocate(c2)
     deallocate(c3)
!
!==== end of loop which updates electronic degrees of freedom
!
!     buffer for wavefunctions is unit 21
!
     if(tbuff) rewind 21

   END SUBROUTINE


!=----------------------------------------------------------------------------=!
   END MODULE
!=----------------------------------------------------------------------------=!
