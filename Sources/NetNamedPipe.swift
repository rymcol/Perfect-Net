//
//  NetNamedPipe.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 7/5/15.
//	Copyright (C) 2015 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

#if os(Linux)
	import SwiftGlibc
	let AF_UNIX: Int32 = 1
	let SOL_SOCKET: Int32 = 1
	let SCM_RIGHTS: Int32 = 0x01
	#else
	import Darwin
#endif

/// This sub-class of NetTCP handles networking over an AF_UNIX named pipe connection.
public class NetNamedPipe : NetTCP {

	/// Initialize the object using an existing file descriptor.
	public convenience init(fd: Int32) {
		self.init()
		self.fd.fd = fd
		self.fd.family = AF_UNIX
		self.fd.switchToNonBlocking()
	}

	/// Override socket initialization to handle the UNIX socket type.
	public override func initSocket() {
	#if os(Linux)
		fd.fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
	#else
		fd.fd = socket(AF_UNIX, SOCK_STREAM, 0)
	#endif
		fd.family = AF_UNIX
		fd.switchToNonBlocking()
	}

	public override func sockName() -> (String, UInt16) {
		var addr = UnsafeMutablePointer<sockaddr_un>.allocate(capacity: 1)
		var len = UnsafeMutablePointer<socklen_t>.allocate(capacity: 1)
		defer {
			addr.deallocate(capacity: 1)
			len.deallocate(capacity: 1)
		}
		len.pointee = socklen_t(sizeof(sockaddr_in.self))
		getsockname(fd.fd, UnsafeMutablePointer<sockaddr>(addr), len)

		var nameBuf = [CChar]()
		let mirror = Mirror(reflecting: addr.pointee.sun_path)
		let childGen = mirror.children.makeIterator()
		for _ in 0..<1024 {
			let (_, elem) = childGen.next()!
			if (elem as! Int8) == 0 {
				break
			}
			nameBuf.append(elem as! Int8)
		}
		nameBuf.append(0)
		let s = String(validatingUTF8: nameBuf) ?? ""
		let p = UInt16(0)

		return (s, p)
	}

	public override func peerName() -> (String, UInt16) {
		var addr = UnsafeMutablePointer<sockaddr_un>.allocate(capacity: 1)
		var len = UnsafeMutablePointer<socklen_t>.allocate(capacity: 1)
		defer {
			addr.deallocate(capacity: 1)
			len.deallocate(capacity: 1)
		}
		len.pointee = socklen_t(sizeof(sockaddr_in.self))
		getpeername(fd.fd, UnsafeMutablePointer<sockaddr>(addr), len)

		var nameBuf = [CChar]()
		let mirror = Mirror(reflecting: addr.pointee.sun_path)
		let childGen = mirror.children.makeIterator()
		for _ in 0..<1024 {
			let (_, elem) = childGen.next()!
			if (elem as! Int8) == 0 {
				break
			}
			nameBuf.append(elem as! Int8)
		}
		nameBuf.append(0)
		let s = String(validatingUTF8: nameBuf) ?? ""
		let p = UInt16(0)

		return (s, p)
	}

	private func makeUNAddr(address addr: String) -> (UnsafeMutablePointer<UInt8>, Int) {
		let utf8 = addr.utf8
#if os(Linux) // BSDs have a size identifier in front, Linux does not
		let addrLen = sizeof(sockaddr_un.self)
#else
		let addrLen = sizeof(UInt8.self) + sizeof(sa_family_t.self) + utf8.count + 1
#endif
		let addrPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: addrLen)

		var memLoc = 0

#if os(Linux) // BSDs use one byte for sa_family_t, Linux uses two
		let afUnixShort = UInt16(AF_UNIX)
		addrPtr[memLoc] = UInt8(afUnixShort & 0xFF)
		memLoc += 1
		addrPtr[memLoc] = UInt8((afUnixShort >> 8) & 0xFF)
		memLoc += 1
#else
		addrPtr[memLoc] = UInt8(addrLen)
		memLoc += 1
		addrPtr[memLoc] = UInt8(AF_UNIX)
		memLoc += 1
#endif

		for char in utf8 {
			addrPtr[memLoc] = char
			memLoc += 1
		}

		addrPtr[memLoc] = 0

		return (addrPtr, addrLen)
	}

	/// Bind the socket to the address path
	/// - parameter address: The path on the file system at which to create and bind the socket
	/// - throws: `PerfectError.NetworkError`
	public func bind(address addr: String) throws {

		initSocket()

		let (addrPtr, addrLen) = self.makeUNAddr(address: addr)
		defer { addrPtr.deallocate(capacity: addrLen) }

	#if os(Linux)
		let bRes = SwiftGlibc.bind(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
		#else
		let bRes = Darwin.bind(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
	#endif
		if bRes == -1 {
			try ThrowNetworkError()
		}
	}

	/// Connect to the indicated server socket
	/// - parameter address: The server socket file.
	/// - parameter timeoutSeconds: The number of seconds to wait for the connection to complete. A timeout of negative one indicates that there is no timeout.
	/// - parameter callBack: The closure which will be called when the connection completes. If the connection completes successfully then the current NetNamedPipe instance will be passed to the callback, otherwise, a nil object will be passed.
	/// - returns: `PerfectError.NetworkError`
	public func connect(address addr: String, timeoutSeconds: Double, callBack: (NetNamedPipe?) -> ()) throws {

		initSocket()

		let (addrPtr, addrLen) = self.makeUNAddr(address: addr)
		defer { addrPtr.deallocate(capacity: addrLen) }

	#if os(Linux)
		let cRes = SwiftGlibc.connect(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
	#else
		let cRes = Darwin.connect(fd.fd, UnsafePointer<sockaddr>(addrPtr), socklen_t(addrLen))
	#endif
		if cRes != -1 {
			callBack(self)
		} else {
			guard errno == EINPROGRESS else {
				try ThrowNetworkError()
			}

			NetEvent.add(socket: fd.fd, what: .write, timeoutSeconds: timeoutSeconds) {
				fd, w in

				if case .timer = w {
					callBack(nil)
				} else {
					callBack(self)
				}
			}
		}
	}

	/// Send the existing opened file descriptor over the connection to the recipient
	/// - parameter fd: The file descriptor to send
	/// - parameter callBack: The callback to call when the send completes. The parameter passed will be `true` if the send completed without error.
	/// - throws: `PerfectError.NetworkError`
	public func sendFd(_ fd: Int32, callBack: (Bool) -> ()) throws {
		let length = sizeof(cmsghdr.self) + sizeof(Int32.self)
	#if os(Linux)
		var msghdr = UnsafeMutablePointer<SwiftGlibc.msghdr>.allocate(capacity: 1)
	#else
		var msghdr = UnsafeMutablePointer<Darwin.msghdr>.allocate(capacity: 1)
	#endif
		var nothingPtr = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
		var nothing = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
		let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: length)
		defer {
			msghdr.deallocate(capacity: 1)
			buffer.deallocate(capacity: length)
			nothingPtr.deallocate(capacity: 1)
			nothing.deallocate(capacity: 1)
		}

		var cmsg = UnsafeMutablePointer<cmsghdr>(buffer)
	#if os(Linux)
		cmsg.pointee.cmsg_len = Int(socklen_t(length))
	#else
		cmsg.pointee.cmsg_len = socklen_t(length)
	#endif
		cmsg.pointee.cmsg_level = SOL_SOCKET
		cmsg.pointee.cmsg_type = SCM_RIGHTS
		let asInts = UnsafeMutablePointer<Int32>(cmsg.advanced(by: 1))
		asInts.pointee = fd

		nothing.pointee = 33

		nothingPtr.pointee.iov_base = UnsafeMutablePointer<Void>(nothing)
		nothingPtr.pointee.iov_len = 1

		msghdr.pointee.msg_name = UnsafeMutablePointer<Void>(nil)
		msghdr.pointee.msg_namelen = 0
		msghdr.pointee.msg_flags = 0
		msghdr.pointee.msg_iov = nothingPtr
		msghdr.pointee.msg_iovlen = 1
		msghdr.pointee.msg_control = UnsafeMutablePointer<Void>(buffer)
	#if os(Linux)
		msghdr.pointee.msg_controllen = Int(socklen_t(length))
	#else
		msghdr.pointee.msg_controllen = socklen_t(length)
	#endif

		let res = sendmsg(Int32(self.fd.fd), msghdr, 0)
		if res > 0 {
			callBack(true)
		} else if res == -1 && errno == EAGAIN {

			NetEvent.add(socket: self.fd.fd, what: .write, timeoutSeconds: NetEvent.noTimeout) { [weak self]
				fd, w in

				do {
					try self?.sendFd(fd, callBack: callBack)
				} catch {
					callBack(false)
				}
			}

		} else {
			try ThrowNetworkError()
		}
	}

	/// Receive an existing opened file descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received file descriptor or invalidSocket.
	/// - throws: `PerfectError.NetworkError`
	public func receiveFd(callBack cb: (Int32) -> ()) throws {
		let length = sizeof(cmsghdr.self) + sizeof(Int32.self)
		var msghdrr = msghdr()
		var nothingPtr = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
		var nothing = UnsafeMutablePointer<CChar>.allocate(capacity: 1)
		let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: length)
		defer {
			buffer.deallocate(capacity: length)
			nothingPtr.deallocate(capacity: 1)
			nothing.deallocate(capacity: 1)
		}

		nothing.pointee = 33

		nothingPtr.pointee.iov_base = UnsafeMutablePointer<Void>(nothing)
		nothingPtr.pointee.iov_len = 1

		msghdrr.msg_iov = UnsafeMutablePointer<iovec>(nothingPtr)
		msghdrr.msg_iovlen = 1
		msghdrr.msg_control = UnsafeMutablePointer<Void>(buffer)
	#if os(Linux)
		msghdrr.msg_controllen = Int(socklen_t(length))
	#else
		msghdrr.msg_controllen = socklen_t(length)
	#endif

		var cmsg = UnsafeMutablePointer<cmsghdr>(buffer)
	#if os(Linux)
		cmsg.pointee.cmsg_len = Int(socklen_t(length))
	#else
		cmsg.pointee.cmsg_len = socklen_t(length)
	#endif
		cmsg.pointee.cmsg_level = SOL_SOCKET
		cmsg.pointee.cmsg_type = SCM_RIGHTS
		let asInts = UnsafeMutablePointer<Int32>(cmsg.advanced(by: 1))
		asInts.pointee = -1

		let res = recvmsg(Int32(self.fd.fd), &msghdrr, 0)
		if res > 0 {
			let receivedInt = asInts.pointee
			cb(receivedInt)
		} else if res == -1 && errno == EAGAIN {

			NetEvent.add(socket: self.fd.fd, what: .read, timeoutSeconds: NetEvent.noTimeout) { [weak self]
				fd, w in

				do {
					try self?.receiveFd(callBack: cb)
				} catch {
					cb(invalidSocket)
				}
			}

		} else {
			try ThrowNetworkError()
		}

	}

	/// Receive an existing opened `NetTCP` descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received `NetTCP` object or nil.
	/// - throws: `PerfectError.NetworkError`
	public func receiveNetTCP(callBack: (NetTCP?) -> ()) throws {
		try self.receiveFd {
			(fd: Int32) -> () in

			if fd == invalidSocket {
				callBack(nil)
			} else {
				callBack(NetTCP(fd: fd))
			}
		}
	}

	/// Receive an existing opened `NetNamedPipe` descriptor from the sender
	/// - parameter callBack: The callback to call when the receive completes. The parameter passed will be the received `NetNamedPipe` object or nil.
	/// - throws: `PerfectError.NetworkError`
	public func receiveNetNamedPipe(callBack: (NetNamedPipe?) -> ()) throws {
		try self.receiveFd {
			(fd: Int32) -> () in

			if fd == invalidSocket {
				callBack(nil)
			} else {
				callBack(NetNamedPipe(fd: fd))
			}
		}
	}

	override func makeFromFd(_ fd: Int32) -> NetTCP {
		return NetNamedPipe(fd: fd)
	}
}
