/**
 * Push-key lookup abstraction — the secret used to mint / validate
 * TencentCloud-CSS-style `?txSecret=<md5>&txTime=<hex>` publish URLs.
 *
 * Current impl returns the single PUBLISH_SIGN_KEY for all streams
 * (one global push key). Future impl will map stream → client → key
 * so a leaked client key only invalidates that client's studios.
 */
export abstract class PushKeyResolver {
  /** Return the push key for this stream, or null if unknown / unconfigured. */
  abstract resolve(stream: string): Promise<string | null>;
}
