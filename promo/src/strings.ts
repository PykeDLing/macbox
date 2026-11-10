import { createContext, useContext } from 'react';

export type Lang = 'zh' | 'en';
export const LangContext = createContext<Lang>('zh');
export const useLang = () => useContext(LangContext);
/** 用法：const t = useT(); t('中文', 'English') */
export const useT = () => {
  const lang = useLang();
  return <A, B>(zh: A, en: B): A | B => (lang === 'zh' ? zh : en);
};

/** 片子里那个“不放心的软件”，用泛指的名字，不点名任何真实产品 */
export const APP = { zh: '某某网盘', en: 'Cloud Drive' } as const;
export const APP_ID = 'com.example.clouddrive';
