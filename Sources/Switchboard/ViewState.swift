import SwiftUI

// SDK 27 exposes a same-named macro absent from Command Line Tools. This selects the public wrapper type.
typealias ViewState<Value> = SwiftUI.State<Value>
