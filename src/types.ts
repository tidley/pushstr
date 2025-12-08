/**
 * Type definitions for Pushstr Nostr extension
 */

// Nostr event structure
export interface NostrEvent {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
}

export interface UnsignedEvent {
  kind: number;
  created_at: number;
  tags: string[][];
  content: string;
  pubkey?: string;
}

// Recipient management
export interface Recipient {
  pubkey: string;
  nickname: string;
}

// Key management
export interface KeyEntry {
  nsec: string;
  pubkey: string;
  nickname: string;
}

// Message storage
export interface Message {
  id: string;
  direction: 'in' | 'out';
  from: string;
  to: string;
  content: string;
  created_at: number;
  outerKind: number;
  relays?: string[];
  relayFrom?: string[];
}

// Settings structure
export interface Settings {
  relays: string[];
  recipients: Recipient[];
  recipientsByKey: Record<string, Recipient[]>;
  nsec: string | null;
  keys: KeyEntry[];
  useGiftwrap: boolean;
  useNip44: boolean;
  lastRecipient: string | null;
  useExternalSigner: boolean;
}

// State shared with popup/options
export interface ExtensionState {
  pubkey: string | null;
  relays: string[];
  recipients: Recipient[];
  messages: Message[];
  useGiftwrap: boolean;
  useNip44: boolean;
  lastRecipient: string | null;
  keys: KeyEntry[];
  useExternalSigner: boolean;
  externalSignerAvailable: boolean;
}

// Message types for browser.runtime communication
export type RuntimeMessage =
  | { type: 'get-state' }
  | { type: 'import-nsec'; value: string }
  | { type: 'generate-key' }
  | { type: 'export-nsec' }
  | { type: 'export-npub' }
  | { type: 'set-last-recipient'; recipient: string }
  | { type: 'upload-blossom'; data: ArrayBuffer; recipient: string; mime: string }
  | { type: 'switch-key'; nsec: string }
  | { type: 'save-settings'; relays?: string[]; recipients?: Recipient[]; useGiftwrap?: boolean; useNip44?: boolean; keyNickname?: string; useExternalSigner?: boolean }
  | { type: 'send-gift'; recipient: string; content: string }
  | { type: 'enable-external-signer' }
  | { type: 'disable-external-signer' }
  | { type: 'incoming'; event: NostrEvent; outer: NostrEvent; message: string };

// Blossom upload response
export interface BlossomUploadResult {
  url?: string;
  sha256?: string;
  size?: number;
  type?: string;
  error?: string;
}

// NIP-07 window.nostr API (external signer)
export interface Nip07Signer {
  getPublicKey(): Promise<string>;
  signEvent(event: UnsignedEvent): Promise<NostrEvent>;
  nip04?: {
    encrypt(pubkey: string, plaintext: string): Promise<string>;
    decrypt(pubkey: string, ciphertext: string): Promise<string>;
  };
  nip44?: {
    encrypt(pubkey: string, plaintext: string): Promise<string>;
    decrypt(pubkey: string, ciphertext: string): Promise<string>;
  };
}

declare global {
  interface Window {
    nostr?: Nip07Signer;
  }
}

// Nostr-tools exports (consolidated)
export interface NostrTools {
  SimplePool: any;
  generateSecretKey(): string;
  getPublicKey(privateKey: string): string;
  getEventHash(event: UnsignedEvent): string;
  signEvent(event: UnsignedEvent, privateKey: string): string;
  verifyEvent(event: NostrEvent): boolean;
  finalizeEvent?(event: UnsignedEvent, privateKey: string): NostrEvent;
  nip19: {
    decode(str: string): { type: string; data: any };
    npubEncode(pubkey: string): string;
    nsecEncode(privateKey: string): string;
  };
  nip04: {
    encrypt(privateKey: string, pubkey: string, plaintext: string): Promise<string>;
    decrypt(privateKey: string, pubkey: string, ciphertext: string): Promise<string>;
  };
  nip44?: {
    getConversationKey(privateKey: string, pubkey: string): Uint8Array;
    encrypt(conversationKey: string | Uint8Array, plaintext: string): Promise<string>;
    decrypt(conversationKey: string | Uint8Array, ciphertext: string): Promise<string>;
  };
}
