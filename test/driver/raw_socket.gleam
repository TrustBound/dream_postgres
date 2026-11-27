//// Plain TCP exchanges with a driver server (see `driver_socket_ffi.erl`),
//// for the tests that write the bytes of one message by hand.

/// Sends `request` to localhost on `port` and gives the one-byte answer to
/// an SSLRequest.
@external(erlang, "driver_socket_ffi", "ssl_answer")
pub fn ssl_answer(port: Int, request: BitArray) -> Result(BitArray, String)

/// Sends `request` to localhost on `port` and gives the first message of
/// the answer.
@external(erlang, "driver_socket_ffi", "first_message")
pub fn first_message(port: Int, request: BitArray) -> Result(BitArray, String)
