import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

export interface SavedCredentials {
  username: string;
  password: string;
}

const ALIAS: Uint8Array = new util.TextEncoder().encodeInto('OHSurfing.campus.credentials');

export class CredentialStore {
  static async load(): Promise<SavedCredentials> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ALIAS);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const records = await asset.query(query);
      if (records.length === 0) return { username: '', password: '' };
      const secret = records[0].get(asset.Tag.SECRET) as Uint8Array;
      if (!secret) return { username: '', password: '' };
      const decoded = JSON.parse(new util.TextDecoder().decodeWithStream(secret)) as SavedCredentials;
      return { username: decoded.username || '', password: decoded.password || '' };
    } catch (_) {
      return { username: '', password: '' };
    }
  }

  static async save(username: string, password: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, ALIAS);
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify({ username, password })));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  static async clear(): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, ALIAS);
    try { await asset.remove(query); } catch (_) { }
  }
}
