import React, { createContext, useContext, useEffect, useRef, useState } from 'react';
import type { User } from '@supabase/supabase-js';
import { supabase, signInWithGoogle, signOutUser, isAuthCancellationError } from '../lib/supabase';
import { doc, getDoc, setDoc } from '../lib/recordStore';
import { UserProfile, UserRole, ClassGroup, SEVEN_DPK_DIVISIONS } from '../types';

type AppUser = User & { uid: string; displayName: string | null; photoURL: string | null };
const toAppUser = (user: User): AppUser => ({ ...user, uid: user.id, displayName: (user.user_metadata?.full_name || user.user_metadata?.name || null) as string | null, photoURL: (user.user_metadata?.avatar_url || user.user_metadata?.picture || null) as string | null });
export const BOOTSTRAP_ADMIN_EMAIL = 'prasetyoadhitama92@gmail.com';
export interface LoginOptions {
  intendedRole?: UserRole;
  preferredDivisionId?: string;
  preferredClass?: ClassGroup;
  accessCode?: string;
}
interface AuthContextType {
  user: AppUser | null; profile: UserProfile | null; profileError: string | null; loading: boolean;
  realRole: UserRole; activeRole: UserRole; previewDivisionId: string; previewClassGroup: ClassGroup;
  isPreviewing: boolean;
  setPreviewContext: (role: UserRole | null, divisionId?: string, classGroup?: ClassGroup) => void;
  clearPreview: () => void; loginWithGoogle: (options?: LoginOptions) => Promise<void>;
  retryProfileSync: () => Promise<void>; logout: () => Promise<void>;
  updateProfileData: (data: Partial<UserProfile>) => Promise<void>;
}
const AuthContext = createContext<AuthContextType | undefined>(undefined);
const clean = <T extends Record<string, any>>(obj: T): T => Object.fromEntries(Object.entries(obj).filter(([,v]) => v !== undefined)) as T;

function fromDb(row: any, user: User): UserProfile {
  return {
    uid: row.id || user.id, email: row.email || user.email || '',
    displayName: row.display_name || user.user_metadata?.full_name || user.user_metadata?.name || 'Warga Sekolah',
    photoURL: row.photo_url || user.user_metadata?.avatar_url || user.user_metadata?.picture || '',
    role: row.role || 'murid', assignedDivisionId: row.assigned_division_id || undefined,
    secondaryDivisionId: row.secondary_division_id || undefined, assignedClassGroup: row.assigned_class_group || undefined,
    studentId: row.student_id || undefined, classGroup: row.class_group || row.assigned_class_group || 'X-1',
    nisn: row.nisn || undefined, canExport: Boolean(row.can_export), inviteCode: row.invite_code || undefined,
    createdAt: row.created_at || new Date().toISOString(), updatedAt: row.updated_at || new Date().toISOString()
  } as UserProfile;
}
function toDb(data: Partial<UserProfile>) {
  const map: Record<string,string> = { displayName:'display_name', photoURL:'photo_url', assignedDivisionId:'assigned_division_id', secondaryDivisionId:'secondary_division_id', assignedClassGroup:'assigned_class_group', studentId:'student_id', classGroup:'class_group', canExport:'can_export', inviteCode:'invite_code', updatedAt:'updated_at' };
  const out: Record<string, any> = {};
  Object.entries(clean(data as Record<string, any>)).forEach(([key,value]) => { out[map[key] || key] = value; });
  return out;
}

async function ensureAdminDefaults(adminEmail: string) {
  const config = await getDoc(doc(null, 'appConfig', 'default'));
  if (!config.exists()) await setDoc(doc(null, 'appConfig', 'default'), {
    id:'default', primaryDivisionWeight:60, secondaryDivisionWeight:40,
    allowStudentDivisionSelection:true, updatedBy:adminEmail, updatedAt:new Date().toISOString()
  });

}

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [user,setUser] = useState<AppUser|null>(null);
  const [profile,setProfile] = useState<UserProfile|null>(null);
  const [profileError,setProfileError] = useState<string|null>(null);
  const [loading,setLoading] = useState(true);
  const manualLogin = useRef(false);
  const [previewRole,setPreviewRole] = useState<UserRole|null>(null);
  const [previewDivisionId,setPreviewDivisionId] = useState(SEVEN_DPK_DIVISIONS[0].id);
  const [previewClassGroup,setPreviewClassGroup] = useState<ClassGroup>('X-1');

  const syncUserFromAuth = async (current: User) => {
    setProfileError(null);
    try {
      const { data, error } = await supabase.from('profiles').select('*').eq('id',current.id).maybeSingle();
      if (error) throw error;
      if (!data) throw new Error('Profil belum dibuat. Jalankan migrasi SQL tahap 2 (RPC onboarding), lalu login kembali.');
      const p = fromDb(data,current);
      setProfile(p);
      if (p.role === 'admin') await ensureAdminDefaults((current.email || '').toLowerCase());
    } catch (err) {
      console.error('Profile sync failed:',err);
      setProfileError(err instanceof Error ? err.message : 'Gagal memuat profil Supabase.');
    }
  };

  const finishOnboarding = async (current: User) => {
    const raw = sessionStorage.getItem('kokurikuler_login_options');
    let options: LoginOptions = {};
    if (raw) { try { options = JSON.parse(raw) as LoginOptions; } catch { options = {}; } }
    const { error } = await supabase.rpc('complete_user_onboarding', {
      p_intended_role: options.intendedRole || 'murid',
      p_preferred_division_id: options.preferredDivisionId || null,
      p_preferred_class: options.preferredClass || 'X-1',
      p_access_code: options.accessCode?.trim().toUpperCase() || null
    });
    if (error) throw error;
    sessionStorage.removeItem('kokurikuler_login_options');
    await syncUserFromAuth(current);
  };

  useEffect(() => {
    let alive = true;
    supabase.auth.getSession().then(async ({data}) => {
      if (!alive) return;
      const current = data.session?.user || null;
      setUser(current ? toAppUser(current) : null);
      if (current) {
        try { if (sessionStorage.getItem('kokurikuler_login_options')) await finishOnboarding(current); else await syncUserFromAuth(current); }
        catch (error) { setProfileError(error instanceof Error ? error.message : 'Gagal menyelesaikan login.'); }
      } else setProfile(null);
      if (alive) setLoading(false);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event,session) => {
      if (manualLogin.current) return;
      const current = session?.user || null;
      setUser(current ? toAppUser(current) : null);
      if (!current) { setProfile(null); setProfileError(null); setPreviewRole(null); setLoading(false); }
      else { queueMicrotask(() => {
        if (!alive) return;
        void (async () => {
          try {
            if (sessionStorage.getItem('kokurikuler_login_options')) await finishOnboarding(current);
            else await syncUserFromAuth(current);
          } catch (error) {
            console.error('Supabase onboarding failed:', error);
            setProfileError(error instanceof Error ? error.message : 'Gagal menyelesaikan login.');
          } finally { setLoading(false); }
        })();
      }); }
    });
    return () => { alive = false; listener.subscription.unsubscribe(); };
  }, []);

  const retryProfileSync = async () => {
    const {data} = await supabase.auth.getUser();
    if (!data.user) return;
    setLoading(true); await syncUserFromAuth(data.user); setLoading(false);
  };

  const loginWithGoogle = async (options?: LoginOptions) => {
    manualLogin.current = true; setLoading(true); setProfileError(null);
    try {
      sessionStorage.setItem('kokurikuler_login_options', JSON.stringify(options || { intendedRole: 'murid' }));
      await signInWithGoogle();
      // Supabase redirects to Google; finishOnboarding runs after the callback returns.
    } catch (error) {
      sessionStorage.removeItem('kokurikuler_login_options');
      if (isAuthCancellationError(error)) console.info('Google sign-in cancelled.');
      else console.error('Google sign-in failed:',error);
      manualLogin.current = false; setLoading(false); throw error;
    }
  };

  const logout = async () => {
    await signOutUser(); setUser(null); setProfile(null); setProfileError(null); setPreviewRole(null);
  };
  const updateProfileData = async (data: Partial<UserProfile>) => {
    if (!user) return;
    const payload = toDb({ ...data, updatedAt:new Date().toISOString() });
    const {error} = await supabase.from('profiles').update(payload).eq('id',user.id);
    if (error) throw error;
    setProfile(prev => prev ? { ...prev, ...data, updatedAt:new Date().toISOString() } : null);
  };

  const realRole: UserRole = profile?.role || ((user?.email || '').toLowerCase() === BOOTSTRAP_ADMIN_EMAIL ? 'admin' : 'murid');
  const activeRole: UserRole = realRole === 'admin' && previewRole ? previewRole : realRole;
  const isPreviewing = realRole === 'admin' && previewRole !== null && previewRole !== 'admin';
  const setPreviewContext = (role: UserRole|null, divisionId?:string, classGroup?:ClassGroup) => {
    if (realRole !== 'admin') return;
    setPreviewRole(role); if (divisionId) setPreviewDivisionId(divisionId); if (classGroup) setPreviewClassGroup(classGroup);
  };
  return <AuthContext.Provider value={{ user,profile,profileError,loading,realRole,activeRole,previewDivisionId,previewClassGroup,isPreviewing,setPreviewContext,clearPreview:()=>setPreviewRole(null),loginWithGoogle,retryProfileSync,logout,updateProfileData }}>{children}</AuthContext.Provider>;
};
export const useAuth = () => { const context = useContext(AuthContext); if (!context) throw new Error('useAuth must be used within an AuthProvider'); return context; };
