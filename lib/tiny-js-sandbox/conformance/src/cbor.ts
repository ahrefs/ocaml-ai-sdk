// The strict CBOR subset of PROTOCOL.md section 2, hand-rolled: definite lengths only; unsigned
// integers up to 2^53-1, text (valid UTF-8), bytes, booleans, null and maps with text keys. Frame
// envelopes are flat, so decoding is not recursive: values are scalars only.

export type Scalar = number | string | Uint8Array | boolean | null;
export type Envelope = Record<string, Scalar>;

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function head(major: number, length: number): Buffer {
	const base = major << 5;
	switch (true) {
		case length < 24:
			return Buffer.from([base | length]);
		case length < 0x100:
			return Buffer.from([base | 24, length]);
		case length < 0x10000: {
			const out = Buffer.alloc(3);
			out[0] = base | 25;
			out.writeUInt16BE(length, 1);
			return out;
		}
		case length < 0x100000000: {
			const out = Buffer.alloc(5);
			out[0] = base | 26;
			out.writeUInt32BE(length, 1);
			return out;
		}
		default: {
			const out = Buffer.alloc(9);
			out[0] = base | 27;
			out.writeBigUInt64BE(BigInt(length), 1);
			return out;
		}
	}
}

function encodeScalar(value: Scalar): Buffer[] {
	switch (typeof value) {
		case "number":
			if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`not an unsigned integer: ${value}`);
			return [head(0, value)];
		case "string": {
			const bytes = encoder.encode(value);
			return [head(3, bytes.length), Buffer.from(bytes)];
		}
		case "boolean":
			return [Buffer.from([value ? 0xf5 : 0xf4])];
		default:
			return value === null ? [Buffer.from([0xf6])] : [head(2, value.length), Buffer.from(value)];
	}
}

/** Encodes a flat map with text keys, `t` first as written by the caller. */
export function encode(envelope: Envelope): Buffer {
	const entries = Object.entries(envelope);
	const parts: Buffer[] = [head(5, entries.length)];
	for (const [key, value] of entries) parts.push(...encodeScalar(key), ...encodeScalar(value));
	return Buffer.concat(parts);
}

class Reader {
	pos = 0;
	constructor(readonly buf: Buffer) {}

	need(n: number): void {
		if (this.pos + n > this.buf.length) throw new Error("CBOR: truncated item");
	}

	/** The argument of the initial byte `info`, as a number (at most 2^53-1). */
	argument(info: number): number {
		switch (true) {
			case info < 24:
				return info;
			case info === 24:
				this.need(1);
				return this.buf[this.pos++];
			case info === 25:
				this.need(2);
				this.pos += 2;
				return this.buf.readUInt16BE(this.pos - 2);
			case info === 26:
				this.need(4);
				this.pos += 4;
				return this.buf.readUInt32BE(this.pos - 4);
			case info === 27: {
				this.need(8);
				const big = this.buf.readBigUInt64BE(this.pos);
				this.pos += 8;
				if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("CBOR: integer above 2^53-1");
				return Number(big);
			}
			default:
				throw new Error(info === 31 ? "CBOR: indefinite length" : "CBOR: reserved additional information");
		}
	}

	scalar(): Scalar {
		this.need(1);
		const initial = this.buf[this.pos++];
		const major = initial >> 5;
		const info = initial & 31;
		switch (major) {
			case 0:
				return this.argument(info);
			case 2:
			case 3: {
				const length = this.argument(info);
				this.need(length);
				const slice = this.buf.subarray(this.pos, this.pos + length);
				this.pos += length;
				return major === 2 ? new Uint8Array(slice) : decoder.decode(slice);
			}
			case 7:
				switch (info) {
					case 20:
						return false;
					case 21:
						return true;
					case 22:
						return null;
					default:
						throw new Error("CBOR: simple value or float not allowed");
				}
			default:
				throw new Error(`CBOR: major type ${major} not allowed here`);
		}
	}
}

/** Decodes one frame payload: a flat map with text keys; rejects everything else and trailing bytes. */
export function decode(buf: Buffer): Envelope {
	const reader = new Reader(buf);
	reader.need(1);
	const initial = buf[reader.pos++];
	if (initial >> 5 !== 5) throw new Error("CBOR: envelope is not a map");
	const count = reader.argument(initial & 31);
	const out: Envelope = {};
	for (let i = 0; i < count; i++) {
		const key = reader.scalar();
		if (typeof key !== "string") throw new Error("CBOR: map key is not text");
		if (Object.hasOwn(out, key)) throw new Error(`CBOR: duplicate key ${key}`);
		out[key] = reader.scalar();
	}
	if (reader.pos !== buf.length) throw new Error("CBOR: trailing bytes");
	return out;
}
