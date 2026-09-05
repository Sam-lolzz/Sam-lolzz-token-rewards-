import { useEffect, useState } from 'react';
import { Alert, ActivityIndicator, Pressable, SafeAreaView, StyleSheet, Text, TextInput, View } from 'react-native';
import * as Linking from 'expo-linking';
import { supabase } from '@/lib/supabase';

type Wallet = { balance: number; streak_count: number; last_claim_at: string | null; handle: string };

export default function Home() {
  const [email, setEmail] = useState('');
  const [loading, setLoading] = useState(true);
  const [wallet, setWallet] = useState<Wallet | null>(null);
  const [recipient, setRecipient] = useState('');
  const [amount, setAmount] = useState('');

  const refresh = async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { setWallet(null); setLoading(false); return; }
    const { data, error } = await supabase.rpc('my_wallet');
    if (error) Alert.alert('Could not load wallet', error.message);
    else setWallet(data?.[0] ?? null);
    setLoading(false);
  };

  useEffect(() => { refresh(); }, []);
  const call = async (name: string, args = {}) => {
    const { error } = await supabase.rpc(name, args);
    if (error) Alert.alert('Not completed', error.message); else { Alert.alert('Done'); refresh(); }
  };
  const signIn = async () => {
    const { error } = await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: Linking.createURL('/') } });
    Alert.alert(error ? 'Sign-in failed' : 'Check your inbox', error?.message ?? 'Use the secure link we sent to continue.');
  };

  if (loading) return <SafeAreaView style={styles.center}><ActivityIndicator color="#7cf5c2" /></SafeAreaView>;
  if (!wallet) return <SafeAreaView style={styles.center}><Text style={styles.title}>Token Rewards</Text><Text style={styles.copy}>Earn test tokens for showing up and completing verified tasks.</Text><TextInput autoCapitalize="none" keyboardType="email-address" placeholder="you@example.com" placeholderTextColor="#7d8995" value={email} onChangeText={setEmail} style={styles.input}/><Pressable style={styles.button} onPress={signIn}><Text style={styles.buttonText}>Email me a sign-in link</Text></Pressable></SafeAreaView>;
  return <SafeAreaView style={styles.page}><Text style={styles.kicker}>WELCOME, @{wallet.handle}</Text><Text style={styles.balance}>{Number(wallet.balance).toLocaleString()} <Text style={styles.token}>TOKENS</Text></Text><Text style={styles.value}>1,000 tokens = $100 â€¢ Cash out from 1,000 tokens</Text><View style={styles.card}><Text style={styles.cardTitle}>Daily reward</Text><Text style={styles.copy}>Claim 0.2 tokens. Your current streak: {wallet.streak_count} days.</Text><Pressable style={styles.button} onPress={() => call('claim_daily_reward')}><Text style={styles.buttonText}>Claim 0.2 tokens</Text></Pressable></View><View style={styles.card}><Text style={styles.cardTitle}>Send tokens</Text><TextInput autoCapitalize="none" placeholder="Recipient handle" placeholderTextColor="#7d8995" value={recipient} onChangeText={setRecipient} style={styles.input}/><TextInput keyboardType="decimal-pad" placeholder="Amount" placeholderTextColor="#7d8995" value={amount} onChangeText={setAmount} style={styles.input}/><Pressable style={styles.button} onPress={() => call('transfer_tokens', { recipient_handle: recipient, token_amount: Number(amount) })}><Text style={styles.buttonText}>Send securely</Text></Pressable></View><Pressable onPress={() => supabase.auth.signOut().then(refresh)}><Text style={styles.signOut}>Sign out</Text></Pressable></SafeAreaView>;
}

const styles = StyleSheet.create({ page:{flex:1,backgroundColor:'#07111d',padding:24,gap:18},center:{flex:1,backgroundColor:'#07111d',padding:24,justifyContent:'center',gap:16},title:{color:'#effff8',fontSize:36,fontWeight:'800'},kicker:{color:'#7cf5c2',fontWeight:'700',letterSpacing:1},balance:{color:'#effff8',fontSize:38,fontWeight:'800'},token:{fontSize:15,color:'#7cf5c2'},value:{color:'#93a4b6'},card:{backgroundColor:'#101f30',borderRadius:18,padding:18,gap:12},cardTitle:{color:'#effff8',fontSize:20,fontWeight:'700'},copy:{color:'#bdcad8',lineHeight:21},input:{backgroundColor:'#152a40',color:'#fff',padding:14,borderRadius:10},button:{backgroundColor:'#7cf5c2',padding:14,borderRadius:10,alignItems:'center'},buttonText:{color:'#042617',fontWeight:'800'},signOut:{color:'#bdcad8',textAlign:'center',padding:12} });

