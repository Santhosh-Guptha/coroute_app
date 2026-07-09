export interface MemberLocation {
  lat: number;
  lng: number;
  speed: number;
  battery: number;
  lastUpdated: number;
  userName: string;
}

export interface SOSAlert {
  alertId: string;
  userId: string;
  userName: string;
  timestamp: number;
  resolved: boolean;
  latitude: number;
  longitude: number;
}

export interface Group {
  groupId: string;
  name: string;
  createdBy: string;
  members: Record<string, boolean>;
  locations: Record<string, MemberLocation>;
  alerts: Record<string, SOSAlert>;
}

type OnGroupUpdate = (group: Group) => void;

class MockDatabaseService {
  private activeGroup: Group | null = null;
  private listeners: Set<OnGroupUpdate> = new Set();
  private simulationInterval: number | null = null;
  private geolocationWatchId: number | null = null;
  
  private currentUserId = "user_me";
  private currentUserName = "You";

  subscribe(callback: OnGroupUpdate): () => void {
    this.listeners.add(callback);
    if (this.activeGroup) {
      callback(this.activeGroup);
    }
    return () => {
      this.listeners.delete(callback);
    };
  }

  private notify() {
    if (this.activeGroup) {
      const groupCopy = JSON.parse(JSON.stringify(this.activeGroup)) as Group;
      this.listeners.forEach((listener) => listener(groupCopy));
    }
  }

  async createGroup(groupName: string, creatorName: string): Promise<string> {
    const code = Math.floor(100000 + Math.random() * 900000).toString();
    this.currentUserName = creatorName;
    
    // Goa trekking starting coordinates
    const initialLat = 15.4909;
    const initialLng = 73.8278;

    this.activeGroup = {
      groupId: code,
      name: groupName,
      createdBy: this.currentUserId,
      members: { [this.currentUserId]: true },
      locations: {
        [this.currentUserId]: {
          lat: initialLat,
          lng: initialLng,
          speed: 0,
          battery: 98,
          lastUpdated: Date.now(),
          userName: creatorName,
        },
      },
      alerts: {},
    };

    this.startSimulation();
    this.notify();
    return code;
  }

  async joinGroup(groupId: string, memberName: string): Promise<boolean> {
    this.currentUserName = memberName;
    
    // Goa trekking starting coordinates
    const initialLat = 15.4909;
    const initialLng = 73.8278;

    this.activeGroup = {
      groupId: groupId,
      name: "Adventure Trek Group",
      createdBy: "user_1",
      members: {
        [this.currentUserId]: true,
        "user_1": true,
        "user_2": true,
        "user_3": true,
      },
      locations: {
        [this.currentUserId]: {
          lat: initialLat,
          lng: initialLng,
          speed: 0,
          battery: 98,
          lastUpdated: Date.now(),
          userName: memberName,
        },
        "user_1": {
          lat: 15.4925,
          lng: 73.8290,
          speed: 4.2,
          battery: 89,
          lastUpdated: Date.now(),
          userName: "Aditya",
        },
        "user_2": {
          lat: 15.4890,
          lng: 73.8255,
          speed: 3.8,
          battery: 74,
          lastUpdated: Date.now(),
          userName: "Neha",
        },
        "user_3": {
          lat: 15.4950,
          lng: 73.8320,
          speed: 4.8,
          battery: 95,
          lastUpdated: Date.now(),
          userName: "Rahul",
        },
      },
      alerts: {},
    };

    this.startSimulation();
    this.notify();
    return true;
  }

  leaveGroup() {
    this.stopSimulation();
    this.activeGroup = null;
    this.listeners.forEach((listener) => listener({
      groupId: "",
      name: "",
      createdBy: "",
      members: {},
      locations: {},
      alerts: {}
    }));
  }

  triggerSOS() {
    if (!this.activeGroup) return;
    const myLoc = this.activeGroup.locations[this.currentUserId];
    const alertId = `alert_${Date.now()}`;
    const alert: SOSAlert = {
      alertId,
      userId: this.currentUserId,
      userName: this.currentUserName,
      timestamp: Date.now(),
      resolved: false,
      latitude: myLoc ? myLoc.lat : 15.4909,
      longitude: myLoc ? myLoc.lng : 73.8278,
    };
    this.activeGroup.alerts[alertId] = alert;
    this.notify();
  }

  resolveSOS(alertId: string) {
    if (!this.activeGroup) return;
    if (this.activeGroup.alerts[alertId]) {
      this.activeGroup.alerts[alertId].resolved = true;
      delete this.activeGroup.alerts[alertId];
      this.notify();
    }
  }

  private startSimulation() {
    this.stopSimulation();
    
    // 1. Simulate mock trekking members movement
    let iteration = 0;
    this.simulationInterval = window.setInterval(() => {
      if (!this.activeGroup) return;
      iteration++;

      const updatedLocations = { ...this.activeGroup.locations };
      
      // Simulate Neha, Aditya, Rahul walking
      const mockIds = ["user_1", "user_2", "user_3"];
      mockIds.forEach((id) => {
        const loc = updatedLocations[id];
        if (loc) {
          const latOffset = (Math.random() - 0.5) * 0.0003;
          const lngOffset = (Math.random() - 0.5) * 0.0003;
          const batteryDrop = Math.random() > 0.85 ? 1 : 0;
          
          updatedLocations[id] = {
            ...loc,
            lat: loc.lat + latOffset,
            lng: loc.lng + lngOffset,
            speed: parseFloat((2 + Math.random() * 4).toFixed(1)),
            battery: Math.max(5, loc.battery - batteryDrop),
            lastUpdated: Date.now(),
          };
        }
      });

      // Simulating our own movement if GPS is simulated
      const myLoc = updatedLocations[this.currentUserId];
      if (myLoc && this.geolocationWatchId === null) {
        // Mock a walking trail for self
        const latOffset = (Math.random() - 0.5) * 0.0002;
        const lngOffset = (Math.random() - 0.5) * 0.0002;
        updatedLocations[this.currentUserId] = {
          ...myLoc,
          lat: myLoc.lat + latOffset,
          lng: myLoc.lng + lngOffset,
          speed: parseFloat((3 + Math.random() * 2).toFixed(1)),
          battery: Math.max(5, myLoc.battery - (Math.random() > 0.9 ? 1 : 0)),
          lastUpdated: Date.now(),
        };
      }

      this.activeGroup.locations = updatedLocations;

      // Automatically trigger a simulated SOS from Neha at iteration 12 to demonstrate UI
      if (iteration === 12 && Object.keys(this.activeGroup.alerts).length === 0) {
        const nehaLoc = updatedLocations["user_2"];
        const alertId = "mock_alert_neha";
        this.activeGroup.alerts[alertId] = {
          alertId,
          userId: "user_2",
          userName: "Neha",
          timestamp: Date.now(),
          resolved: false,
          latitude: nehaLoc ? nehaLoc.lat : 15.4890,
          longitude: nehaLoc ? nehaLoc.lng : 73.8255,
        };
      }

      this.notify();
    }, 3000);

    // 2. Try to capture real GPS position of the user
    if ("geolocation" in navigator) {
      this.geolocationWatchId = navigator.geolocation.watchPosition(
        (position) => {
          if (!this.activeGroup) return;
          const updatedLocations = { ...this.activeGroup.locations };
          const speedKmh = position.coords.speed ? position.coords.speed * 3.6 : 0;
          
          updatedLocations[this.currentUserId] = {
            lat: position.coords.latitude,
            lng: position.coords.longitude,
            speed: parseFloat(speedKmh.toFixed(1)),
            battery: 100, // Hardcoded battery or estimated
            lastUpdated: Date.now(),
            userName: this.currentUserName,
          };
          this.activeGroup.locations = updatedLocations;
          this.notify();
        },
        (error) => {
          console.warn("Geolocation watch error, using mock path:", error);
          this.geolocationWatchId = null;
        },
        { enableHighAccuracy: true, timeout: 5000, maximumAge: 0 }
      );
    }
  }

  private stopSimulation() {
    if (this.simulationInterval) {
      clearInterval(this.simulationInterval);
      this.simulationInterval = null;
    }
    if (this.geolocationWatchId !== null) {
      navigator.geolocation.clearWatch(this.geolocationWatchId);
      this.geolocationWatchId = null;
    }
  }
}

export const MockDatabase = new MockDatabaseService();
