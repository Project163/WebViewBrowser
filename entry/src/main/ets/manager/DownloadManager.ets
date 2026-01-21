/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { request } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0001;
const TAG = 'DownloadManager';

// 下载状态枚举
export enum DownloadState {
  IDLE = 0,
  QUEUED = 1,
  DOWNLOADING = 2,
  PAUSED = 3,
  COMPLETED = 4,
  FAILED = 5,
  CANCELED = 6
}

// 下载项接口定义
export interface DownloadItem {
  id: string;              // 唯一标识 (通常是时间戳+随机数)
  // taskId?: string;      // 移除 taskId，因为 DownloadTask 不直接暴露，且我们有对象引用
  url: string;             // 下载地址
  fileName: string;        // 保存的文件名
  filePath: string;        // 保存的完整路径
  state: DownloadState;    // 当前状态
  progress: number;        // 进度 0-100
  receivedSize: number;    // 已接收字节
  totalSize: number;       // 总字节
  speed: number;           // 下载速度 (bytes/s)
  createTime: number;      // 创建时间
  finishTime?: number;     // 完成时间
  mimeType?: string;       // MIME类型
  errorMessage?: string;   // 错误信息
}

// 监听器接口
export interface DownloadListener {
  onProgress: (item: DownloadItem) => void;
  onStatusChange: (item: DownloadItem) => void;
  onError: (item: DownloadItem, error: string) => void;
}

/**
 * 下载管理器 - 单例模式
 * 负责管理所有下载任务，持久化下载记录，并提供UI回调
 */
export class DownloadManager {
  private static instance: DownloadManager;
  private context: common.UIAbilityContext | null = null;
  private preferences: preferences.Preferences | null = null;
  private downloadList: DownloadItem[] = [];
  private listeners: Set<DownloadListener> = new Set();

  // 内存中维护的request任务映射
  private taskMap: Map<string, request.DownloadTask> = new Map();

  private constructor() {}

  public static getInstance(): DownloadManager {
    if (!DownloadManager.instance) {
      DownloadManager.instance = new DownloadManager();
    }
    return DownloadManager.instance;
  }

  /**
   * 初始化管理器
   * @param context 应用上下文
   */
  public async init(context: common.UIAbilityContext): Promise<void> {
    if (this.context) {
      return;
    }
    this.context = context;
    hilog.info(DOMAIN, TAG, 'DownloadManager initializing...');

    try {
      this.preferences = await preferences.getPreferences(context, 'browser_downloads');
      await this.loadDownloadHistory();
      hilog.info(DOMAIN, TAG, 'DownloadManager initialized successfully');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to init DownloadManager: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 开始新的下载任务
   * @param url 下载链接
   * @param suggestedName 建议的文件名
   * @param mimeType 文件类型
   * @param contentLength 文件大小
   */
  public async startDownload(url: string, suggestedName?: string, mimeType?: string, contentLength?: number): Promise<boolean> {
    if (!this.context) {
      hilog.error(DOMAIN, TAG, 'Context is null, cannot start download');
      return false;
    }

    try {
      // 1. 生成唯一ID和文件名
      const id = this.generateId();
      const fileName = this.sanitizeFileName(suggestedName || this.getFileNameFromUrl(url));
      // 使用应用沙箱路径 cache 目录作为下载目录
      const downloadDir = this.context.cacheDir;
      const filePath = `${downloadDir}/${fileName}`;

      // 2. 创建下载项记录
      const newItem: DownloadItem = {
        id: id,
        url: url,
        fileName: fileName,
        filePath: filePath,
        state: DownloadState.QUEUED,
        progress: 0,
        receivedSize: 0,
        totalSize: contentLength || 0,
        speed: 0,
        createTime: Date.now(),
        mimeType: mimeType
      };

      this.downloadList.unshift(newItem);
      this.notifyStatusChange(newItem);
      await this.saveDownloadHistory();

      // 3. 启动系统下载任务
      try {
        const config: request.DownloadConfig = {
          url: url,
          header: {},
          enableMetered: true,
          enableRoaming: true,
          filePath: filePath,
          title: fileName
        };

        request.downloadFile(this.context, config).then((task: request.DownloadTask) => {
          // newItem.taskId = task.tid; // 已移除：DownloadTask 无 tid 属性，使用 taskMap 管理引用
          newItem.state = DownloadState.DOWNLOADING;
          this.taskMap.set(newItem.id, task);

          this.attachTaskListeners(task, newItem);
          this.notifyStatusChange(newItem);
          hilog.info(DOMAIN, TAG, 'Download task started: %{public}s', fileName);
        }).catch((err: BusinessError) => {
          this.handleTaskError(newItem, `Start failed: ${err.message}`);
        });

      } catch (reqErr) {
        this.handleTaskError(newItem, `Request creation failed: ${(reqErr as BusinessError).message}`);
        return false;
      }

      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Unexpected error in startDownload: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  /**
   * 绑定任务监听器
   */
  private attachTaskListeners(task: request.DownloadTask, item: DownloadItem) {
    try {
      // 进度监听
      task.on('progress', (receivedSize: number, totalSize: number) => {
        // 计算速度 (简单模拟，实际应用可配合时间戳计算)
        const diff = receivedSize - item.receivedSize;
        if (diff > 0) {
          item.speed = diff;
        }

        item.receivedSize = receivedSize;
        if (totalSize > 0) {
          item.totalSize = totalSize;
          item.progress = Math.floor((receivedSize / totalSize) * 100);
        }
        item.state = DownloadState.DOWNLOADING;
        this.notifyProgress(item);
      });

      // 完成监听
      task.on('complete', () => {
        hilog.info(DOMAIN, TAG, 'Task complete: %{public}s', item.fileName);
        item.state = DownloadState.COMPLETED;
        item.progress = 100;
        item.finishTime = Date.now();
        item.receivedSize = item.totalSize; // 确保一致

        // 移除任务引用
        this.taskMap.delete(item.id);
        this.saveDownloadHistory();
        this.notifyStatusChange(item);
      });

      // 失败监听
      task.on('fail', (err: number) => {
        hilog.error(DOMAIN, TAG, 'Task failed: %{public}s, code: %{public}d', item.fileName, err);
        item.state = DownloadState.FAILED;
        item.errorMessage = `Error code: ${err}`;
        this.taskMap.delete(item.id);
        this.saveDownloadHistory();
        this.notifyStatusChange(item);
        this.notifyError(item, `Download failed with code ${err}`);
      });

    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Error attaching listeners: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 暂停/恢复/取消操作
   */
  public async operateTask(id: string, action: 'pause' | 'resume' | 'cancel'): Promise<void> {
    const item = this.downloadList.find(d => d.id === id);
    if (!item) return;

    const task = this.taskMap.get(id);

    // 对于取消操作，即使没有运行中的任务，也需要更新状态
    if (action === 'cancel') {
      if (task) {
        try {
          await task.delete(); // 删除任务
        } catch (e) {}
        this.taskMap.delete(id);
      }
      // 如果文件存在，尝试删除
      try {
        if (fs.accessSync(item.filePath)) {
          fs.unlinkSync(item.filePath);
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'Failed to delete file: %{public}s', item.filePath);
      }

      // 从列表中移除
      const index = this.downloadList.findIndex(d => d.id === id);
      if (index !== -1) {
        this.downloadList.splice(index, 1);
      }
      await this.saveDownloadHistory();
      this.notifyStatusChange(item); // 实际上item已经被移除了，UI层需要处理
      return;
    }

    if (!task) {
      // 尝试恢复不在内存中的任务比较复杂，这里仅处理内存中的
      hilog.warn(DOMAIN, TAG, 'Task not found in memory map');
      return;
    }

    try {
      if (action === 'pause') {
        await task.suspend();
        item.state = DownloadState.PAUSED;
      } else if (action === 'resume') {
        await task.restore();
        item.state = DownloadState.DOWNLOADING;
      }
      this.notifyStatusChange(item);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Operate task failed: %{public}s', JSON.stringify(err));
      this.notifyError(item, `Operation ${action} failed`);
    }
  }

  /**
   * 清除所有历史记录 (保留文件)
   */
  public async clearHistory(deleteFiles: boolean = false): Promise<void> {
    if (deleteFiles) {
      // 遍历删除文件
      for (const item of this.downloadList) {
        try {
          if (fs.accessSync(item.filePath)) {
            fs.unlinkSync(item.filePath);
          }
        } catch (e) {}
      }
    }
    this.downloadList = [];
    this.taskMap.clear(); // 清理引用
    await this.saveDownloadHistory();
  }
  

  // ================= 辅助方法 =================

  private handleTaskError(item: DownloadItem, msg: string) {
    item.state = DownloadState.FAILED;
    item.errorMessage = msg;
    this.notifyStatusChange(item);
    this.notifyError(item, msg);
    this.saveDownloadHistory();
  }

  private generateId(): string {
    return `${Date.now()}_${Math.floor(Math.random() * 1000)}`;
  }

  private getFileNameFromUrl(url: string): string {
    try {
      const parts = url.split('/');
      let name = parts[parts.length - 1];
      if (name.includes('?')) {
        name = name.split('?')[0];
      }
      return name || `download_${Date.now()}`;
    } catch (e) {
      return `download_${Date.now()}`;
    }
  }

  // 清理文件名中的非法字符
  private sanitizeFileName(name: string): string {
    return name.replace(/[\\/:*?"<>|]/g, '_');
  }

  // ================= 持久化 =================

  private async loadDownloadHistory() {
    if (!this.preferences) return;
    try {
      const jsonStr = await this.preferences.get('download_list', '[]') as string;
      const list = JSON.parse(jsonStr) as DownloadItem[];
      // 恢复时，所有 'DOWNLOADING' 状态的应该重置为 'PAUSED' 或 'FAILED'，因为进程重启后任务对象丢失
      this.downloadList = list.map(item => {
        if (item.state === DownloadState.DOWNLOADING || item.state === DownloadState.QUEUED) {
          item.state = DownloadState.PAUSED;
        }
        return item;
      });
      hilog.info(DOMAIN, TAG, 'Loaded %{public}d download items', this.downloadList.length);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to load history: %{public}s', JSON.stringify(err));
    }
  }

  private async saveDownloadHistory() {
    if (!this.preferences) return;
    try {
      await this.preferences.put('download_list', JSON.stringify(this.downloadList));
      await this.preferences.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to save history: %{public}s', JSON.stringify(err));
    }
  }

  // ================= 监听器管理 =================

  public getDownloadList(): DownloadItem[] {
    return [...this.downloadList];
  }

  public addListener(listener: DownloadListener) {
    this.listeners.add(listener);
  }

  public removeListener(listener: DownloadListener) {
    this.listeners.delete(listener);
  }

  private notifyProgress(item: DownloadItem) {
    this.listeners.forEach(l => l.onProgress(item));
  }

  private notifyStatusChange(item: DownloadItem) {
    this.listeners.forEach(l => l.onStatusChange(item));
  }

  private notifyError(item: DownloadItem, msg: string) {
    this.listeners.forEach(l => l.onError(item, msg));
  }

  // 格式化文件大小工具方法
  public static formatFileSize(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }
}

// 导出全局单例
export const downloadManager = DownloadManager.getInstance();