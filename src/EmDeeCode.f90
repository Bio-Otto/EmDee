!   This file is part of EmDee.
!
!    EmDee is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    EmDee is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with EmDee. If not, see <http://www.gnu.org/licenses/>.
!
!    Author: Charlles R. A. Abreu (abreu@eq.ufrj.br)
!            Applied Thermodynamics and Molecular Simulation
!            Federal University of Rio de Janeiro, Brazil

! TODO: Replace type(c_ptr) arguments by array arguments when possible
! TODO: Create indexing for having sequential body particles and free particles in arrays

module EmDeeCode

use EmDeeData

implicit none

private

character(11), parameter :: VERSION = "28 Dec 2016"

type, bind(C) :: tOpts
  integer(ib) :: translate      ! Flag to activate/deactivate translations
  integer(ib) :: rotate         ! Flag to activate/deactivate rotations
  integer(ib) :: rotationMode   ! Algorithm used for free rotation of rigid bodies
end type tOpts

type, bind(C) :: tEmDee
  integer(ib) :: builds         ! Number of neighbor list builds
  real(rb)    :: pairTime       ! Time taken in force calculations
  real(rb)    :: totalTime      ! Total time since initialization
  real(rb)    :: Potential      ! Total potential energy of the system
  real(rb)    :: Kinetic        ! Total kinetic energy of the system
  real(rb)    :: Rotational     ! Rotational kinetic energy of the system
  real(rb)    :: Virial         ! Total internal virial of the system
  type(c_ptr) :: layerEnergy    ! A vector with the energies due to multilayer models
  integer(ib) :: DOF            ! Total number of degrees of freedom
  integer(ib) :: rotationDOF    ! Number of rotational degrees of freedom
  type(c_ptr) :: Data           ! Pointer to system data
  type(tOpts) :: Options        ! List of options to change EmDee's behavior
end type tEmDee

contains

!===================================================================================================
!                                L I B R A R Y   P R O C E D U R E S
!===================================================================================================

  function EmDee_system( threads, layers, rc, skin, N, types, masses ) bind(C,name="EmDee_system")
    integer(ib), value :: threads, layers, N
    real(rb),    value :: rc, skin
    type(c_ptr), value :: types, masses
    type(tEmDee)       :: EmDee_system

    integer :: i
    integer,     pointer :: ptype(:)
    real(rb),    pointer :: pmass(:)
    type(tData), pointer :: me
    type(pairModelContainer) :: none

    write(*,'("EmDee (version: ",A11,")")') VERSION

    ! Allocate data structure:
    allocate( me )

    ! Set up fixed entities:
    me%nthreads = threads
    me%nlayers = layers
    me%Rc = rc
    me%RcSq = rc*rc
    me%xRc = rc + skin
    me%xRcSq = me%xRc**2
    me%skinSq = skin*skin
    me%natoms = N
    me%fshift = one/me%RcSq
    me%eshift = -two/me%Rc

    ! Set up atom types:
    if (c_associated(types)) then
      call c_f_pointer( types, ptype, [N] )
      if (minval(ptype) /= 1) stop "ERROR: wrong specification of atom types."
      me%ntypes = maxval(ptype)
      allocate( me%atomType(N), source = ptype )
    else
      me%ntypes = 1
      allocate( me%atomType(N), source = 1 )
    end if

    ! Set up atomic masses:
    if (c_associated(masses)) then
      call c_f_pointer( masses, pmass, [me%ntypes] )
      allocate( me%mass(N), source = pmass(ptype) )
      allocate( me%invMass(N), source = one/pmass(ptype) )
      me%totalMass = sum(pmass(ptype))
    else
      allocate( me%mass(N), source = one )
      allocate( me%invMass(N), source = one )
      me%totalMass = real(N,rb)
    end if

    ! Initialize counters and other mutable entities:
    me%startTime = omp_get_wtime()
    allocate( me%P(3,N), me%F(3,N), me%R0(3,N), source = zero )
    allocate( me%charge(N), source = zero )
    allocate( me%cell(0) )
    allocate( me%atomCell(N) )

    ! Allocate variables associated to rigid bodies:
    allocate( me%body(me%nbodies) )
    me%nfree = N
    allocate( me%free(N), source = [(i,i=1,N)] )
    me%threadAtoms = (N + threads - 1)/threads

    ! Allocate memory for list of atoms per cell:
    call me % cellAtom % allocate( N, 0 )

    ! Allocate memory for neighbor lists:
    allocate( me%neighbor(threads) )
    call me % neighbor % allocate( extra, N )

    ! Allocate memory for the list of pairs excluded from the neighbor lists:
    call me % excluded % allocate( extra, N )

    ! Allocate memory for pair models:
    allocate( none%model, source = pair_none(name="none") )
    allocate( me%pair(me%ntypes,me%ntypes,me%nlayers), source = none )
    allocate( me%multilayer(me%ntypes,me%ntypes), source = .false. )
    allocate( me%overridable(me%ntypes,me%ntypes), source = .true. )
    allocate( me%layer_energy(me%nlayers) )

    ! Set up mutable entities:
    EmDee_system % builds = 0
    EmDee_system % pairTime = zero
    EmDee_system % totalTime = zero
    EmDee_system % Potential = zero
    EmDee_system % Kinetic = zero
    EmDee_system % Rotational = zero
    EmDee_system % layerEnergy = c_loc(me%layer_energy(1))
    EmDee_system % DOF = 3*(N - 1)
    EmDee_system % rotationDOF = 0
    EmDee_system % data = c_loc(me)
    EmDee_system % Options % translate = 1
    EmDee_system % Options % rotate = 1
    EmDee_system % Options % rotationMode = 0

  end function EmDee_system

!===================================================================================================

  subroutine EmDee_switch_model_layer( md, layer ) bind(C,name="EmDee_switch_model_layer")
    type(tEmDee), value :: md
    integer(ib),  value :: layer

    type(tData), pointer :: me

    call c_f_pointer( md%data, me )
    if ((layer < 1).or.(layer > me%nlayers)) stop "ERROR in model layer change: out of range"
    if (me%initialized) call update_forces( md, layer )
    me%layer = layer

  end subroutine EmDee_switch_model_layer

!===================================================================================================

  subroutine EmDee_set_pair_model( md, itype, jtype, model ) bind(C,name="EmDee_set_pair_model")
    type(tEmDee), value :: md
    integer(ib),  value :: itype, jtype
    type(c_ptr),  value :: model

    integer :: layer, ktype
    type(tData), pointer :: me
    type(modelContainer), pointer :: container

    call c_f_pointer( md%data, me )
    if (me%initialized) stop "ERROR: cannot set pair type after coordinates have been defined"
    if (.not.c_associated(model)) stop "ERROR: a valid pair model must be provided"

    call c_f_pointer( model, container )
    do layer = 1, me%nlayers
      call set_pair_type( me, itype, jtype, layer, container )
    end do

    me%multilayer(itype,jtype) = .false.
    me%multilayer(jtype,itype) = .false.
    if (itype == jtype) then
      do ktype = 1, me%ntypes
        if ((ktype /= itype).and.me%overridable(itype,ktype)) then
          me%multilayer(itype,ktype) = me%multilayer(ktype,ktype)
          me%multilayer(ktype,itype) = me%multilayer(ktype,ktype)
        end if
      end do
    else
      me%overridable(itype,jtype) = .false.
      me%overridable(jtype,itype) = .false.
    end if

  end subroutine EmDee_set_pair_model

!===================================================================================================

  subroutine EmDee_set_pair_multimodel( md, itype, jtype, model ) bind(C,name="EmDee_set_pair_multimodel")
    type(tEmDee), value      :: md
    integer(ib),  value      :: itype, jtype
    type(c_ptr),  intent(in) :: model(*)

    integer :: layer, ktype
    character(5) :: C
    type(tData), pointer :: me
    type(modelContainer), pointer :: container

    call c_f_pointer( md%data, me )

    if (me%initialized) stop "ERROR: cannot set pair type after coordinates have been defined"

    do layer = 1, me%nlayers
      if (c_associated(model(layer))) then
        call c_f_pointer( model(layer), container )
      else
        write(C,'(I5)') me%nlayers
        call error( "set_pair_multimodel", trim(adjustl(C))//" valid pair models must be provided" )
      end if
      call set_pair_type( me, itype, jtype, layer, container )
    end do

    me%multilayer(itype,jtype) = .true.
    me%multilayer(jtype,itype) = .true.
    if (itype == jtype) then
      do ktype = 1, me%ntypes
        if ((ktype /= itype).and.me%overridable(itype,ktype)) then
          me%multilayer(itype,ktype) = .true.
          me%multilayer(ktype,itype) = .true.
        end if
      end do
    else
      me%overridable(itype,jtype) = .false.
      me%overridable(jtype,itype) = .false.
    end if

  end subroutine EmDee_set_pair_multimodel

!===================================================================================================

  subroutine EmDee_ignore_pair( md, i, j ) bind(C,name="EmDee_ignore_pair")
    type(tEmDee), value :: md
    integer(ib),  value :: i, j

    integer :: n
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )
    if ((i > 0).and.(i <= me%natoms).and.(j > 0).and.(j <= me%natoms).and.(i /= j)) then
      associate (excluded => me%excluded)
        n = excluded%count
        if (n == excluded%nitems) call excluded % resize( n + extra )
        call add_item( excluded, i, j )
        call add_item( excluded, j, i )
        excluded%count = n
      end associate
    end if

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine add_item( excluded, i, j )
        type(tList), intent(inout) :: excluded
        integer,     intent(in)    :: i, j
        integer :: start, end
        start = excluded%first(i)
        end = excluded%last(i)
        if (end < start) then
          excluded%item(end+2:n+1) = excluded%item(end+1:n)
          excluded%item(end+1) = j
        elseif (j > excluded%item(end)) then ! Repetition avoids exception in DEBUB mode
          excluded%item(end+2:n+1) = excluded%item(end+1:n)
          excluded%item(end+1) = j
        else
          do while (j > excluded%item(start))
            start = start + 1
          end do
          if (j == excluded%item(start)) return
          excluded%item(start+1:n+1) = excluded%item(start:n)
          excluded%item(start) = j
          start = start + 1
        end if
        excluded%first(i+1:) = excluded%first(i+1:) + 1
        excluded%last(i:) = excluded%last(i:) + 1
        n = n + 1
      end subroutine add_item
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_ignore_pair

!===================================================================================================

  subroutine EmDee_add_bond( md, i, j, model ) bind(C,name="EmDee_add_bond")
    type(tEmDee), value :: md
    integer(ib),  value :: i, j
    type(c_ptr),  value :: model

    type(tData),          pointer :: me
    type(modelContainer), pointer :: container

    call c_f_pointer( md%data, me )

    if (.not.c_associated(model)) stop "ERROR: a valid bond model must be provided"
    call c_f_pointer( model, container )

    select type (bmodel => container%model)
      class is (cBondModel)
        call me % bonds % add( i, j, 0, 0, bmodel )
        call EmDee_ignore_pair( md, i, j )
      class default
        stop "ERROR: a valid bond model must be provided"
    end select

  end subroutine EmDee_add_bond

!===================================================================================================

  subroutine EmDee_add_angle( md, i, j, k, model ) bind(C,name="EmDee_add_angle")
    type(tEmDee), value :: md
    integer(ib),  value :: i, j, k
    type(c_ptr),  value :: model

    type(tData), pointer :: me
    type(modelContainer), pointer :: container

    call c_f_pointer( md%data, me )

    if (.not.c_associated(model)) stop "ERROR: a valid angle model must be provided"
    call c_f_pointer( model, container )

    select type (amodel => container%model)
      class is (cAngleModel)
        call me % angles % add( i, j, k, 0, amodel )
        call EmDee_ignore_pair( md, i, j )
        call EmDee_ignore_pair( md, i, k )
        call EmDee_ignore_pair( md, j, k )
      class default
        stop "ERROR: a valid angle model must be provided"
    end select

  end subroutine EmDee_add_angle

!===================================================================================================

  subroutine EmDee_add_dihedral( md, i, j, k, l, model ) bind(C,name="EmDee_add_dihedral")
    type(tEmDee), value :: md
    integer(ib),  value :: i, j, k, l
    type(c_ptr),  value :: model

    type(tData), pointer :: me
    type(modelContainer), pointer :: container

    call c_f_pointer( md%data, me )

    if (.not.c_associated(model)) stop "ERROR: a valid dihedral model must be provided"
    call c_f_pointer( model, container )

    select type (dmodel => container%model)
      class is (cDihedralModel)
        call me % dihedrals % add( i, j, k, l, dmodel )
        call EmDee_ignore_pair( md, i, j )
        call EmDee_ignore_pair( md, i, k )
        call EmDee_ignore_pair( md, i, l )
        call EmDee_ignore_pair( md, j, k )
        call EmDee_ignore_pair( md, j, l )
        call EmDee_ignore_pair( md, k, l )
      class default
        stop "ERROR: a valid dihedral model must be provided"
    end select

  end subroutine EmDee_add_dihedral

!===================================================================================================

  subroutine EmDee_add_rigid_body( md, N, indexes ) bind(C,name="EmDee_add_rigid_body")
    type(tEmDee), value :: md
    type(c_ptr),  value :: indexes
    integer(ib),  value :: N

    integer, parameter :: extraBodies = 100

    integer :: i, j
    logical,  allocatable :: isFree(:)
    real(rb), allocatable :: Rn(:,:)
    integer,      pointer :: atom(:)
    type(tData),  pointer :: me

    type(tBody), allocatable :: body(:)

    call c_f_pointer( indexes, atom, [N] )
    call c_f_pointer( md%data, me )

    allocate( isFree(me%natoms) )
    isFree = .false.
    isFree(me%free(1:me%nfree)) = .true.
    isFree(atom) = .false.
    me%nfree = me%nfree - N
    md%DOF = md%DOF - 3*N
    if (count(isFree) /= me%nfree) stop "Error adding rigid body: only free atoms are allowed."
    me%free(1:me%nfree) = pack([(i,i=1,me%natoms)],isFree)
    me%threadAtoms = (me%nfree + me%nthreads - 1)/me%nthreads

    if (me%nbodies == size(me%body)) then
      allocate( body(me%nbodies + extraBodies) )
      body(1:me%nbodies) = me%body
      deallocate( me%body )
      call move_alloc( body, me%body )
    end if
    me%nbodies = me%nbodies + 1
    me%threadBodies = (me%nbodies + me%nthreads - 1)/me%nthreads
    associate(b => me%body(me%nbodies))
      call b % setup( atom, me%mass(atom) )
      if (me%initialized) then
        Rn = me%R(:,atom)
        forall (j=2:b%NP) Rn(:,j) = Rn(:,j) - me%Lbox*anint((Rn(:,j) - Rn(:,1))*me%invL)
        call b % update( Rn )
        me%R(:,b%index) = Rn
      end if
      md%DOF = md%DOF + b%dof
      md%rotationDOF = md%rotationDOF + b%dof - 3
    end associate
    do i = 1, N-1
      do j = i+1, N
        call EmDee_ignore_pair( md, atom(i), atom(j) )
      end do
    end do

  end subroutine EmDee_add_rigid_body

!===================================================================================================

  subroutine EmDee_upload( md, option, address ) bind(C,name="EmDee_upload")
    type(tEmDee),      intent(inout) :: md
    character(c_char), intent(in)    :: option(*)
    type(c_ptr),       value         :: address

    real(rb) :: twoKEt, twoKEr
    real(rb), pointer :: L, Ext(:,:)
    type(tData), pointer :: me
    character(sl) :: item

    call c_f_pointer( md%data, me )
    item = string(option)
    if (.not.c_associated(address)) call error( "upload", "provided address is invalid" )

    select case (item)

      case ("box")
        call c_f_pointer( address, L )
        me%Lbox = L
        me%invL = one/L
        me%invL2 = me%invL**2
        me%initialized = allocated( me%R )
        if (me%initialized) call compute_forces( md )

      case ("coordinates")
        if (.not.allocated( me%R )) allocate( me%R(3,me%natoms) )
        call c_f_pointer( address, Ext, [3,me%natoms] )
        !$omp parallel num_threads(me%nthreads)
        call assign_coordinates( me, omp_get_thread_num() + 1, Ext )
        !$omp end parallel
        me%initialized = me%Lbox > zero
        if (me%initialized) call compute_forces( md )

      case ("momenta")
        if (.not.me%initialized) call error( "upload", "box and coordinates have not been defined" )
        call c_f_pointer( address, Ext, [3,me%natoms] )
        !$omp parallel num_threads(me%nthreads) reduction(+:TwoKEt,TwoKEr)
        call assign_momenta( me, omp_get_thread_num() + 1, Ext, twoKEt, twoKEr )
        !$omp end parallel

      case ("forces")
        if (.not.me%initialized) call error( "upload", "box and coordinates have not been defined" )
        call c_f_pointer( address, Ext, [3,me%natoms] )
        !$omp parallel num_threads(me%nthreads)
        call assign_forces( omp_get_thread_num() + 1 )
        !$omp end parallel

      case ("charges")
        call c_f_pointer( address, Ext, [me%natoms,1] )
        !$omp parallel num_threads(me%nthreads)
        call assign_charges( omp_get_thread_num() + 1 )
        !$omp end parallel
        if (me%initialized) call compute_forces( md )

      case default
        call error( "upload", "invalid option" )

    end select

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine assign_forces( thread )
        integer, intent(in) :: thread
        integer :: i, j
        do j = (thread - 1)*me%threadAtoms + 1, min(thread*me%threadAtoms, me%nfree)
          i = me%free(j)
          me%F(:,i) = Ext(:,i)
        end do
        do i = (thread - 1)*me%threadBodies + 1, min(thread*me%threadBodies, me%nbodies)
          call me % body(i) % force_torque_virial( Ext )
        end do
      end subroutine assign_forces
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine assign_charges( thread )
        integer, intent(in) :: thread
        integer :: first, last
        first = (thread - 1)*me%threadAtoms + 1
        last = min(thread*me%threadAtoms, me%natoms)
        me%charge(first:last) = Ext(first:last,1)
      end subroutine assign_charges
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_upload

!===================================================================================================

  subroutine EmDee_download( md, Lbox, coords, momenta, forces ) bind(C,name="EmDee_download")
    type(tEmDee), value :: md
    type(c_ptr),  value :: Lbox, coords, momenta, forces

    real(rb),    pointer :: L, Pext(:,:), Rext(:,:), Fext(:,:)
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )

    if (c_associated(Lbox)) then
      call c_f_pointer( Lbox, L )
      L = me%Lbox
    end if

    if (c_associated(coords)) then
      call c_f_pointer( coords, Rext, [3,me%natoms] )
      Rext = me%R
    end if

    if (c_associated(forces)) then
      call c_f_pointer( forces, Fext, [3,me%natoms] )
      Fext = me%F
    end if

    if (c_associated(momenta)) then
      call c_f_pointer( momenta, Pext, [3,me%natoms] )
      !$omp parallel num_threads(me%nthreads)
      call get_momenta( omp_get_thread_num() + 1 )
      !$omp end parallel
    end if

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine get_momenta( thread )
        integer, intent(in) :: thread
        integer :: i
        forall (i = (thread - 1)*me%threadAtoms + 1 : min(thread*me%threadAtoms, me%nfree))
          Pext(:,me%free(i)) = me%P(:,me%free(i))
        end forall
        forall(i = (thread - 1)*me%threadBodies + 1 : min(thread*me%threadBodies,me%nbodies))
          Pext(:,me%body(i)%index) = me%body(i) % particle_momenta()
        end forall
      end subroutine get_momenta
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_download

!===================================================================================================

  subroutine EmDee_random_momenta( md, kT, adjust, seed ) bind(C,name="EmDee_random_momenta")
    type(tEmDee), intent(inout) :: md
    real(rb),     value         :: kT
    integer(ib),  value         :: adjust, seed

    integer  :: i, j
    real(rb) :: twoKEt, TwoKEr
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )
    if (me%random%seeding_required) call me % random % setup( seed )
    twoKEt = zero
    TwoKEr = zero
    associate (rng => me%random)
      if (me%nbodies /= 0) then
        if (.not.me%initialized) stop "ERROR in random momenta: coordinates not defined."
        do i = 1, me%nbodies
          associate (b => me%body(i))
            b%pcm = sqrt(b%mass*kT)*[rng%normal(), rng%normal(), rng%normal()]
            call b%assign_momenta( sqrt(b%invMoI*kT)*[rng%normal(), rng%normal(), rng%normal()] )
            twoKEt = twoKEt + b%invMass*sum(b%pcm*b%pcm)
            TwoKEr = TwoKEr + sum(b%MoI*b%omega**2)
          end associate
        end do
      end if
      do j = 1, me%nfree
        i = me%free(j)
        me%P(:,i) = sqrt(me%mass(i)*kT)*[rng%normal(), rng%normal(), rng%normal()]
        twoKEt = twoKEt + sum(me%P(:,i)**2)/me%mass(i)
      end do
    end associate
    if (adjust == 1) call adjust_momenta
    md%Rotational = half*TwoKEr
    md%Kinetic = half*(twoKEt + TwoKEr)

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine adjust_momenta
        integer  :: i
        real(rb) :: vcm(3), factor
        associate (free => me%free(1:me%nfree), body => me%body(1:me%nbodies))
          forall (i=1:3) vcm(i) = (sum(me%P(i,free)) + sum(body(1:me%nbodies)%pcm(i)))/me%totalMass
          forall (i=1:me%nfree) me%P(:,free(i)) = me%P(:,free(i)) - me%mass(free(i))*vcm
          forall (i=1:me%nbodies) body(i)%pcm = body(i)%pcm - body(i)%mass*vcm
          twoKEt = sum([(sum(me%P(:,free(i))**2)*me%invMass(free(i)),i=1,me%nfree)]) + &
                   sum([(sum(body(i)%pcm**2)*body(i)%invMass,i=1,me%nbodies)])
          factor = sqrt((3*me%nfree + sum(body%dof) - 3)*kT/(twoKEt + TwoKEr))
          me%P(:,free) = factor*me%P(:,free)
          do i = 1, me%nbodies
            associate( b => body(i) )
              b%pcm = factor*b%pcm
              call b%assign_momenta( factor*b%omega )
            end associate
          end do
        end associate
        twoKEt = factor*factor*twoKEt
        TwoKEr = factor*factor*TwoKEr
      end subroutine adjust_momenta
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_random_momenta

!===================================================================================================

!  subroutine EmDee_save_state( md, rigid )
!    type(tEmDee), intent(inout) :: md
!    integer(ib),  intent(in)    :: rigid
!    if (rigid /= 0) then
!    else
!    end if
!  end subroutine EmDee_save_state

!===================================================================================================

!  subroutine EmDee_restore_state( md )
!    type(tEmDee), intent(inout) :: md
!  end subroutine EmDee_restore_state

!===================================================================================================

  subroutine EmDee_boost( md, lambda, alpha, dt ) bind(C,name="EmDee_boost")
    type(tEmDee), intent(inout) :: md
    real(rb),     value         :: lambda, alpha, dt

    real(rb) :: CP, CF, Ctau, twoKEt, twoKEr, KEt
    logical  :: tflag, rflag
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )

    CF = phi(alpha*dt)*dt
    CP = one - alpha*CF
    CF = lambda*CF
    Ctau = two*CF

    tflag = md % Options % translate /= 0
    rflag = md % Options % rotate /= 0
    twoKEt = zero
    twoKEr = zero
    !$omp parallel num_threads(me%nthreads) reduction(+:twoKEt,twoKEr)
    call boost( omp_get_thread_num() + 1, twoKEt, twoKEr )
    !$omp end parallel
    if (tflag) then
      KEt = half*twoKEt
    else
      KEt = md%Kinetic - md%Rotational
    end if
    if (rflag) md%Rotational = half*twoKEr
    md%Kinetic = KEt + md%Rotational

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine boost( thread, twoKEt, twoKEr )
        integer,  intent(in)    :: thread
        real(rb), intent(inout) :: twoKEt, twoKEr
        integer  :: i, j
        do i = (thread - 1)*me%threadBodies + 1, min(thread*me%threadBodies, me%nbodies)
          associate(b => me%body(i))
            if (tflag) then
              b%pcm = CP*b%pcm + CF*b%F
              twoKEt = twoKEt + b%invMass*sum(b%pcm*b%pcm)
            end if
            if (rflag) then
              call b%assign_momenta( CP*b%pi + matmul( matrix_C(b%q), Ctau*b%tau ) )
              twoKEr = twoKEr + sum(b%MoI*b%omega*b%Omega)
            end if
          end associate
        end do
        if (tflag) then
          do i = (thread - 1)*me%threadAtoms + 1, min(thread*me%threadAtoms, me%nfree)
            j = me%free(i)
            me%P(:,j) = CP*me%P(:,j) + CF*me%F(:,j)
            twoKEt = twoKEt + me%invMass(j)*sum(me%P(:,j)**2)
          end do
        end if
      end subroutine boost
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_boost

!===================================================================================================

  subroutine EmDee_move( md, lambda, alpha, dt ) bind(C,name="EmDee_move")
    type(tEmDee), intent(inout) :: md
    real(rb),     value         :: lambda, alpha, dt

    real(rb) :: cR, cP
    logical  :: tflag, rflag
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )

    if (alpha /= zero) then
      cP = phi(alpha*dt)*dt
      cR = one - alpha*cP
      me%Lbox = cR*me%Lbox
      me%InvL = one/me%Lbox
      me%invL2 = me%invL*me%invL
    else
      cP = dt
      cR = one
    end if
    cP = lambda*cP

    tflag = md % Options % translate /= 0
    rflag = md % Options % rotate /= 0

    !$omp parallel num_threads(me%nthreads)
    call move( omp_get_thread_num() + 1, cP, cR )
    !$omp end parallel

    call compute_forces( md )

    contains
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
      subroutine move( thread, cP, cR )
        integer,  intent(in) :: thread
        real(rb), intent(in) :: cP, cR
        integer :: i, j
        do i = (thread - 1)*me%threadBodies + 1, min(thread*me%threadBodies, me%nbodies)
          associate(b => me%body(i))
            if (tflag) b%rcm = cR*b%rcm + cP*b%invMass*b%pcm
            if (rflag) then
              if (md%Options%rotationMode == 0) then
               call b % rotate_exact( dt )
              else
                call b % rotate_no_squish( dt, n = md%options%rotationMode )
              end if
              forall (j=1:3) me%R(j,b%index) = b%rcm(j) + b%delta(j,:)
            end if
          end associate
        end do
        if (tflag) then
          do i = (thread - 1)*me%threadAtoms + 1, min(thread*me%threadAtoms, me%nfree)
            j = me%free(i)
            me%R(:,j) = cR*me%R(:,j) + cP*me%P(:,j)*me%invMass(j)
          end do
        end if
      end subroutine move
      !- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  end subroutine EmDee_move

!===================================================================================================
!                              A U X I L I A R Y   P R O C E D U R E S
!===================================================================================================

  subroutine compute_forces( md )
    type(tEmDee), intent(inout) :: md

    integer  :: M
    real(rb) :: time, E, W
    logical  :: buildList
    real(rb), allocatable :: Rs(:,:), Fs(:,:,:), Elayer(:,:)
    type(tData),  pointer :: me

    call c_f_pointer( md%data, me )
    md%pairTime = md%pairTime - omp_get_wtime()

    allocate( Rs(3,me%natoms), Fs(3,me%natoms,me%nthreads), Elayer(me%nlayers,me%nthreads) )
    Rs = me%invL*me%R

    buildList = maximum_approach_sq( me%natoms, me%R - me%R0 ) > me%skinSq
    if (buildList) then
      M = floor(ndiv*me%Lbox/me%xRc)
      call distribute_atoms( me, max(M,2*ndiv+1), Rs )
      me%R0 = me%R
      md%builds = md%builds + 1
    endif

    !$omp parallel num_threads(me%nthreads) reduction(+:E,W)
    block
      integer :: thread
      thread = omp_get_thread_num() + 1
      associate( F => Fs(:,:,thread) )
        if (buildList) then
          call find_pairs_and_compute( me, thread, Rs, F, E, W, Elayer(:,thread) )
        else
          call compute_pairs( me, thread, Rs, F, E, W, Elayer(:,thread) )
        end if
        if (me%bonds%exist) call compute_bonds( me, thread, Rs, F, E, W )
        if (me%angles%exist) call compute_angles( me, thread, Rs, F, E, W )
        if (me%dihedrals%exist) call compute_dihedrals( me, thread, Rs, F, E, W )
      end associate
    end block
    !$omp end parallel

    me%F = me%Lbox*sum(Fs,3)
    md%Potential = E
    md%Virial = third*W
    me%layer_energy = sum(Elayer,2)
    if (me%nbodies /= 0) call rigid_body_forces( me, md%Virial )

    time = omp_get_wtime()
    md%pairTime = md%pairTime + time
    md%totalTime = time - me%startTime

  end subroutine compute_forces

!===================================================================================================

  subroutine update_forces( md, layer )
    type(tEmDee), intent(inout) :: md
    integer,      intent(in)    :: layer

    real(rb) :: DE, DW, time
    real(rb), allocatable :: Rs(:,:), DFs(:,:,:)
    type(tData),  pointer :: me

    call c_f_pointer( md%data, me )
    md%pairTime = md%pairTime - omp_get_wtime()

    allocate( Rs(3,me%natoms), DFs(3,me%natoms,me%nthreads) )
    Rs = me%invL*me%R

    !$omp parallel num_threads(me%nthreads) reduction(+:DE,DW)
    block
      integer :: thread
      thread = omp_get_thread_num() + 1
      call update_pairs( me, thread, Rs, DFs(:,:,thread), DE, DW, layer )
    end block
    !$omp end parallel

    me%F = me%F + me%Lbox*sum(DFs,3)
    md%Potential = md%Potential + DE
    md%Virial = md%Virial + third*DW
    if (me%nbodies /= 0) call rigid_body_forces( me, md%Virial )

    time = omp_get_wtime()
    md%pairTime = md%pairTime + time
    md%totalTime = time - me%startTime

  end subroutine update_forces

!===================================================================================================

  subroutine EmDee_Rotational_Energies( md, Kr ) bind(C,name="EmDee_Rotational_Energies")
    type(tEmDee), value   :: md
    real(rb), intent(out) :: Kr(3)

    integer :: i
    type(tData), pointer :: me

    call c_f_pointer( md%data, me )

    Kr = zero
    do i = 1, me%nbodies
      Kr = Kr + me%body(i)%MoI*me%body(i)%omega**2
    end do
    Kr = half*Kr

  end subroutine EmDee_Rotational_Energies

!===================================================================================================

  subroutine error( routine, msg )
    use, intrinsic :: iso_fortran_env
    character(*), intent(in) :: routine, msg
    write(ERROR_UNIT,'("Error in EmDee_",A,": ",A,".")') trim(routine), trim(msg)
    stop
  end subroutine error

!===================================================================================================

  character(sl) function string( carray )
    character(c_char), intent(in) :: carray(*)
    integer :: i
    string = ""
    do i = 1, sl
      if (carray(i) == c_null_char) return
      string(i:i) = carray(i)
    end do
  end function string

!===================================================================================================

end module EmDeeCode
