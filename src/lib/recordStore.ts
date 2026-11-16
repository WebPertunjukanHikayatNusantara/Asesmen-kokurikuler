export type Unsubscribe = () => void;
/* Compatibility data adapter over Supabase app_records.
 * Keeps the existing StudentContext data model intact during backend migration.
 * All authorization is enforced by PostgreSQL RLS, never by this client adapter.
 */
import { supabase } from './supabase';

type Row = { collection_name: string; id: string; data: Record<string, any> };
type Filter = { field: string; value: unknown };
type Ref = { collection: string; id?: string; filters?: Filter[] };
type SnapDoc = { id: string; exists: () => boolean; data: () => Record<string, any> };
type Snap = { exists: () => boolean; data: () => Record<string, any> | undefined; forEach: (fn: (doc: SnapDoc) => void) => void; docs: SnapDoc[] };
const makeDoc = (row: Row): SnapDoc => ({ id: row.id, exists: () => true, data: () => row.data || {} });
const makeSnap = (rows: Row[]): Snap => {
  const docs = rows.map(makeDoc);
  return { exists: () => docs.length > 0, data: () => docs[0]?.data(), docs, forEach: (fn) => docs.forEach(fn) };
};
const asError = (error: any): never => { throw new Error(error?.message || String(error)); };

export const db = { __supabase: true };
export function collection(_db: unknown, name: string): Ref { return { collection: name }; }
export function doc(_db: unknown, collectionName: string, id: string): Ref { return { collection: collectionName, id }; }
export function where(field: string, _op: '==', value: unknown): Filter { return { field, value }; }
export function query(ref: Ref, ...filters: Filter[]): Ref { return { ...ref, filters: [...(ref.filters || []), ...filters] }; }

async function fetchRows(ref: Ref): Promise<Row[]> {
  let request = supabase.from('app_records').select('collection_name,id,data').eq('collection_name', ref.collection);
  if (ref.id) request = request.eq('id', ref.id);
  const { data, error } = await request;
  if (error) asError(error);
  let rows = (data || []) as Row[];
  if (ref.filters?.length) rows = rows.filter(row => ref.filters!.every(f => row.data?.[f.field] === f.value));
  return rows;
}

export async function getDoc(ref: Ref): Promise<Snap> { return makeSnap(await fetchRows(ref)); }
export async function getDocFromServer(ref: Ref): Promise<Snap> { return getDoc(ref); }
export async function setDoc(ref: Ref, value: Record<string, any>, options?: { merge?: boolean }): Promise<void> {
  let payload = value;
  if (options?.merge) {
    const current = await fetchRows(ref);
    payload = { ...(current[0]?.data || {}), ...value };
  }
  const { error } = await supabase.from('app_records').upsert({ collection_name: ref.collection, id: ref.id!, data: payload, updated_at: new Date().toISOString() }, { onConflict: 'collection_name,id' });
  if (error) asError(error);
}
export async function updateDoc(ref: Ref, patch: Record<string, any>): Promise<void> {
  const current = await fetchRows(ref);
  if (!current.length) { const missing = new Error(`Record ${ref.collection}/${ref.id} tidak ditemukan.`) as Error & { code?: string }; missing.code = 'not-found'; throw missing; }
  const { error } = await supabase.from('app_records').update({ data: { ...current[0].data, ...patch }, updated_at: new Date().toISOString() }).eq('collection_name', ref.collection).eq('id', ref.id!);
  if (error) asError(error);
}
export async function deleteDoc(ref: Ref): Promise<void> {
  const { error } = await supabase.from('app_records').delete().eq('collection_name', ref.collection).eq('id', ref.id!);
  if (error) asError(error);
}
export function onSnapshot(ref: Ref, next: (snap: Snap) => void, fail?: (error: any) => void): () => void {
  let alive = true;
  let pending = false;
  const refresh = async () => {
    if (!alive || pending) return;
    pending = true;
    try { const rows = await fetchRows(ref); if (alive) next(makeSnap(rows)); }
    catch (error) { if (alive) fail?.(error); }
    finally { pending = false; }
  };
  void refresh();
  const channel = supabase.channel(`records-${ref.collection}-${Math.random().toString(36).slice(2)}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'app_records', filter: `collection_name=eq.${ref.collection}` }, () => void refresh())
    .subscribe((status) => { if (status === 'SUBSCRIBED') void refresh(); });
  return () => { alive = false; void supabase.removeChannel(channel); };
}

export function writeBatch(_db: unknown) {
  const writes: Array<{ kind: 'set' | 'delete'; ref: Ref; data?: Record<string, any> }> = [];
  return {
    set(ref: Ref, data: Record<string, any>) { writes.push({ kind: 'set', ref, data }); },
    delete(ref: Ref) { writes.push({ kind: 'delete', ref }); },
    async commit() {
      const sets = writes.filter(w => w.kind === 'set');
      const deletes = writes.filter(w => w.kind === 'delete');
      for (const w of deletes) await deleteDoc(w.ref);
      if (sets.length) {
        const payload = sets.map(w => ({ collection_name: w.ref.collection, id: w.ref.id!, data: w.data || {} }));
        const { error } = await supabase.rpc('admin_upsert_records_batch', { p_records: payload });
        if (error) asError(error);
      }
    }
  };
}

export enum OperationType { CREATE='create', UPDATE='update', DELETE='delete', LIST='list', GET='get', WRITE='write' }
export function handleDataError(error: unknown, operationType: OperationType, path: string | null): never {
  const message = error instanceof Error ? error.message : String(error);
  console.error('Supabase data error:', { message, operationType, path });
  throw new Error(message);
}
