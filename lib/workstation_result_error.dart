/// An explicit business rejection returned by a workstation endpoint.
class WorkstationResultError extends StateError {
  WorkstationResultError(super.message, this.resultCode);

  final int resultCode;
}
