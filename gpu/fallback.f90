! ============================================================================
! OLWSX - OverLab Web ServerX
! File: gpu/fallback.f90
! Role: Final numerical fallback (deterministic CPU routines)
! ----------------------------------------------------------------------------

module olwsx_fallback
  implicit none
contains

  subroutine xor_transform(data, n, key)
    integer, intent(in) :: n
    integer, intent(in) :: key
    integer :: i
    integer, intent(inout) :: data(n)
    do i = 1, n
      data(i) = ieor(data(i), key)
    end do
  end subroutine xor_transform

  subroutine stats_mean_std(data, n, mean, std)
    integer, intent(in) :: n
    integer, intent(in) :: data(n)
    real(8), intent(out) :: mean, std
    integer :: i
    real(8) :: s, var

    if (n <= 0) then
      mean = 0.0d0
      std  = 0.0d0
      return
    end if

    s = 0.0d0
    do i = 1, n
      s = s + dble(data(i))
    end do
    mean = s / dble(n)

    var = 0.0d0
    do i = 1, n
      var = var + (dble(data(i)) - mean)**2
    end do
    var = var / dble(n)
    std = sqrt(var)
  end subroutine stats_mean_std

end module olwsx_fallback